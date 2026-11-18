import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// NextDNS bar widget and panel. The bar shows the logo, which turns into a
// warning or a crossed-out outline when DNS is not being filtered. The panel is
// three quiet blocks: status with the service switch, the last 24 hours from
// the NextDNS API, and a footer with the connection and dashboard links.
Panel {
  id: root
  moduleName: "io.github.cempack.nextdns"
  ipcTarget: "io.github.cempack.nextdns"
  manageIpc: false

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color accent: Commons.Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color faint: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.1)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string st: dns.state
  // Unencrypted still filters, so it gets the "!" but not the red: red is
  // kept for DNS that escapes NextDNS or cannot reach it.
  readonly property bool danger: st === "leaking" || st === "offline"
  readonly property bool warning: danger || st === "unencrypted"
  readonly property bool stopped: st === "stopped" || st === "missing"
  readonly property string mark: warning ? "alert" : stopped ? "off" : "logo"
  readonly property color barIconColor: danger ? urgent : stopped ? Qt.darker(barForeground, 1.55) : barForeground

  readonly property string accountUrl: "https://my.nextdns.io/account"
  // Stats can be dismissed; the choice is a widget setting in shell.json.
  // _statsChoice holds a click (-1 none, 0 hide, 1 show) until settings catch up.
  property int _statsChoice: -1
  readonly property bool statsSetting: setting("showStats", true) !== false
  readonly property bool showStats: _statsChoice === -1 ? statsSetting : _statsChoice === 1
  onStatsSettingChanged: _statsChoice = -1

  readonly property bool needsKey: showStats && (dns.statsState === "nokey" || dns.statsState === "auth")
  readonly property bool hasStats: showStats && dns.statsState === "ok"

  // 0 → 1 when the panel opens or fresh stats land; figures count up and the
  // chart grows with it.
  property real reveal: 1
  NumberAnimation on reveal {
    id: revealAnimation
    running: false
    from: 0
    to: 1
    duration: Style.duration(280)
    easing.type: Easing.OutCubic
  }

  function setShowStats(on) {
    _statsChoice = on ? 1 : 0
    Quickshell.execDetached(["omarchy-bar", "set", root.moduleName, "showStats", on ? "true" : "false", "--json"])
    if (on) dns.refresh(false, true, true)
  }

  // The hero lives in the panel's lazily built content; null until first open.
  readonly property Item hero: panel.loadedContent ? panel.loadedContent.hero : null

  property bool cursorActive: false
  // Hour under the pointer in the chart, -1 when none.
  property int hoverHour: -1

  // 1234 → "1,234", 45600 → "45.6k", 4560000 → "4.6M", in the user's number format.
  function compact(n) {
    n = Number(n) || 0
    if (n >= 1e6) return strings.t("unit.millions").arg(Commons.I18n.formatNumber(n / 1e6, n >= 1e7 ? 0 : 1))
    if (n >= 1e4) return strings.t("unit.thousands").arg(Commons.I18n.formatNumber(n / 1e3, n >= 1e5 ? 0 : 1))
    return Commons.I18n.formatNumber(n)
  }

  function percent(share) {
    var p = share * 100
    return strings.t("unit.percent").arg(Commons.I18n.formatNumber(p, p > 0 && p < 10 ? 1 : 0))
  }

  function hourLabel(index) {
    var start = new Date(dns.statsAt - (dns.statsSeries.length - index) * 3600000)
    return start.toLocaleTimeString(Qt.locale(Commons.I18n.formatLocale), "HH:00")
  }

  readonly property real seriesMax: {
    var max = 1
    for (var i = 0; i < dns.statsSeries.length; i++) max = Math.max(max, Number(dns.statsSeries[i][0]) || 0)
    return max
  }

  readonly property string metaText: {
    switch (st) {
    case "protected": return dns.protocol !== "" ? strings.t("meta.protectedVia").arg(dns.protocol) : strings.t("meta.protected")
    case "unencrypted": return strings.t("meta.unencrypted").arg(dns.protocol)
    case "leaking": return strings.t("meta.leaking")
    case "offline": return strings.t("meta.offline")
    case "stopped": return strings.t("meta.stopped")
    case "missing": return strings.t("meta.missing")
    default: return strings.t("meta.checking")
    }
  }

  // Facts the status line cycles through while all is well.
  readonly property var phrases: {
    var list = [metaText]
    if (st !== "protected") return list
    if (hasStats && dns.statsBlocked > 0) {
      list.push(strings.t("phrase.blocked").arg(compact(dns.statsBlocked)))
      list.push(strings.t("phrase.share").arg(percent(dns.blockedShare)))
    }
    if (dns.server !== "") list.push(strings.t("phrase.server").arg(dns.server))
    return list
  }
  property int phraseIndex: 0
  readonly property string heroMeta: phrases[phraseIndex % phrases.length]

  readonly property string hintText: dns.lastError !== "" ? strings.t(dns.lastError)
    : st === "unencrypted" ? strings.t("hint.unencrypted")
    : st === "leaking" ? strings.t("hint.leaking")
    : ""

  function toggleService() {
    if (dns.installed && !dns.busy) dns.setActive(!dns.active)
  }

  function openPage(page) {
    dns.openUrl(page === "account" ? accountUrl : dns.dashboardUrl + page)
    close()
  }

  onOpenedChanged: if (opened) {
    cursorActive = false
    hoverHour = -1
    phraseIndex = 0
    dns.refresh(true, showStats)
    if (hasStats) revealAnimation.restart()
    Qt.callLater(function() { if (panel.loadedContent) panel.loadedContent.forceActiveFocus() })
  }

  Connections {
    target: dns
    function onStatsAtChanged() { if (root.opened && root.hasStats) revealAnimation.restart() }
  }

  Timer {
    interval: 3200
    repeat: true
    running: root.opened && root.phrases.length > 1
    onTriggered: phraseSwap.restart()
  }

  SequentialAnimation {
    id: phraseSwap
    PropertyAnimation { target: root.hero; property: "metaOpacity"; to: 0; duration: Style.duration(140); easing.type: Easing.OutCubic }
    ScriptAction { script: root.phraseIndex = (root.phraseIndex + 1) % root.phrases.length }
    PropertyAnimation { target: root.hero; property: "metaOpacity"; to: 1; duration: Style.duration(200); easing.type: Easing.OutCubic }
  }

  Service {
    id: dns
    settings: root.settings
    pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, "")
  }

  ShellIpc {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { dns.refresh(true, true, true); return "ok" }
    function status(): string { return dns.state }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: "NextDNS · " + root.metaText
    iconComponent: Component {
      NextDnsIcon {
        iconSize: button.iconSize
        color: root.barIconColor
        mark: root.mark
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) dns.refresh(true, root.opened && root.showStats, true)
      else if (buttonCode === Qt.MiddleButton) dns.openUrl(dns.dashboardUrl)
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(640))

    content: PanelKeyCatcher {
      property alias hero: hero
      anchors.fill: parent
      implicitHeight: column.implicitHeight
      // The switch is the only cursor stop; links have letter shortcuts.
      onMoveRequested: function(dx, dy) { root.cursorActive = true }
      onActivateRequested: if (root.cursorActive) root.toggleService()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var k = String(t).toLowerCase()
        if (k === "r") dns.refresh(true, root.showStats, true)
        else if (k === "s") root.toggleService()
        else if (k === "d") root.openPage("setup")
        else if (k === "l") root.openPage("logs")
        else if (k === "a") root.openPage("analytics")
        else if (k === "k") root.openPage("account")
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(18)

        // ── Status ──────────────────────────────────────────────────────────
        Column {
          width: parent.width
          spacing: Style.space(8)

          PanelHero {
            id: hero
            width: parent.width
            title: "NextDNS"
            meta: root.heroMeta
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.stopped ? 0.55 : 1.0
            iconComponent: Component {
              NextDnsIcon {
                iconSize: Style.font.display
                color: root.danger ? root.urgent : root.stopped ? root.foreground : root.accent
                mark: root.mark
              }
            }
            trailingControl: Component {
              ToggleSwitch {
                id: powerSwitch
                visible: dns.installed && dns.loaded
                checked: dns.active
                busy: dns.busy
                foreground: root.foreground
                hasCursor: root.cursorActive
                onHovered: function(on) { if (on) root.cursorActive = true }
                onToggled: root.toggleService()

                PanelToolTip {
                  visible: powerSwitch.containsMouse
                  text: dns.active ? strings.t("switch.stop") : strings.t("switch.start")
                  fontFamily: root.fontFamily
                }
              }
            }
          }

          Caption {
            visible: root.hintText !== ""
            width: parent.width
            text: root.hintText
            color: root.danger || dns.lastError !== "" ? root.urgent : root.dim
            wrapMode: Text.WordWrap
          }
        }

        // ── Last 24 hours ───────────────────────────────────────────────────
        Column {
          visible: root.showStats && dns.installed && dns.profile !== ""
          width: parent.width
          spacing: Style.space(12)

          Item {
            width: parent.width
            implicitHeight: sectionTitle.implicitHeight

            PanelSectionHeader {
              id: sectionTitle
              text: strings.t("stats.title")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            // Hovered hour, read from the chart.
            Caption {
              anchors.right: parent.right
              anchors.baseline: sectionTitle.baseline
              visible: root.hoverHour >= 0 && root.hoverHour < dns.statsSeries.length
              text: visible
                ? strings.t("stats.hour")
                    .arg(root.hourLabel(root.hoverHour))
                    .arg(Commons.I18n.formatNumber(dns.statsSeries[root.hoverHour][0]))
                    .arg(Commons.I18n.formatNumber(dns.statsSeries[root.hoverHour][1]))
                : ""
            }
          }

          // Three figures, unboxed.
          RowLayout {
            visible: root.hasStats
            width: parent.width
            spacing: Style.space(8)

            Figure { label: strings.t("stats.queries"); value: root.compact(dns.statsTotal * root.reveal) }
            Figure { label: strings.t("stats.blocked"); value: root.compact(dns.statsBlocked * root.reveal) }
            Figure { label: strings.t("stats.share"); value: root.percent(dns.blockedShare * root.reveal); highlight: true }
          }

          // Hourly chart: full bar = all queries, accent part = blocked.
          Item {
            id: chart
            visible: root.hasStats && dns.statsSeries.length > 0
            width: parent.width
            height: Style.space(44)

            readonly property int count: dns.statsSeries.length
            readonly property real gap: Style.space(2)
            readonly property real barWidth: count > 0 ? Math.max(1, (width - gap * (count - 1)) / count) : 0

            Repeater {
              model: dns.statsSeries
              Item {
                id: hourBar
                required property var modelData
                required property int index
                readonly property real total: Number(modelData[0]) || 0
                readonly property real blocked: Number(modelData[1]) || 0
                // Each bar starts a little after its left neighbour.
                readonly property real grown: Math.max(0, Math.min(1, root.reveal * 1.5 - 0.5 * index / Math.max(1, chart.count)))
                x: index * (chart.barWidth + chart.gap)
                width: chart.barWidth
                height: chart.height
                opacity: root.hoverHour < 0 || root.hoverHour === index ? 1 : 0.4

                Rectangle {
                  anchors.bottom: parent.bottom
                  width: parent.width
                  height: Math.max(Style.space(2), parent.height * hourBar.grown * hourBar.total / root.seriesMax)
                  radius: Math.min(Style.cornerRadius, width / 2)
                  color: root.faint

                  Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width
                    height: hourBar.total > 0 ? parent.height * hourBar.blocked / hourBar.total : 0
                    radius: parent.radius
                    color: root.accent
                  }
                }

                Behavior on opacity { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              onPositionChanged: function(mouse) {
                root.hoverHour = Math.max(0, Math.min(chart.count - 1, Math.floor(mouse.x / (chart.barWidth + chart.gap))))
              }
              onExited: root.hoverHour = -1
            }
          }

          // Most blocked domains, each washed by its share of the top one.
          Column {
            visible: root.hasStats && dns.statsTop.length > 0
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              model: dns.statsTop
              DomainRow {
                required property var modelData
                width: parent.width
                domain: String(modelData.domain || "")
                queries: Number(modelData.queries) || 0
                share: dns.statsTop[0].queries > 0 ? root.reveal * queries / dns.statsTop[0].queries : 0
              }
            }
          }

          KeyEntry {
            visible: root.needsKey
            width: parent.width
          }

          Caption {
            visible: dns.statsState === "error" || (dns.statsState === "idle" && dns.statsAt === 0)
            text: dns.statsState === "error" ? strings.t("stats.error") : strings.t("stats.loading")
          }
        }

        // ── Footer: where DNS goes, and the dashboard ───────────────────────
        RowLayout {
          visible: dns.installed
          width: parent.width
          spacing: Style.space(4)

          Caption {
            Layout.fillWidth: true
            text: [dns.server, dns.clientIp].filter(function(v) { return v !== "" }).join("  ·  ")
            elide: Text.ElideRight
          }

          PanelActionButton {
            visible: !root.showStats
            iconText: "󰈈"
            tooltipText: strings.t("stats.show")
            foreground: root.accent
            fontFamily: root.fontFamily
            Layout.alignment: Qt.AlignVCenter
            onClicked: root.setShowStats(true)
          }

          LinkButton { glyph: "󰄨"; page: "analytics"; tip: strings.t("action.analytics") }
          LinkButton { glyph: "󰌱"; page: "logs"; tip: strings.t("action.logs") }
          LinkButton { glyph: "󰕮"; page: "setup"; tip: strings.t("action.dashboard") }
        }
      }
    }
  }

  // ── Pieces ──────────────────────────────────────────────────────────────

  component Caption: Text {
    textFormat: Text.PlainText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  component Figure: Column {
    id: figure
    property string label: ""
    property string value: ""
    property bool highlight: false

    Layout.fillWidth: true
    Layout.preferredWidth: 1
    spacing: Style.space(1)

    Text {
      width: parent.width
      text: figure.value
      textFormat: Text.PlainText
      color: figure.highlight ? root.accent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
      font.bold: true
      elide: Text.ElideRight
    }

    Caption {
      width: parent.width
      text: figure.label
      elide: Text.ElideRight
    }
  }

  component DomainRow: Item {
    id: domainRow
    property string domain: ""
    property real queries: 0
    property real share: 0

    implicitHeight: domainText.implicitHeight + Style.space(8)

    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: parent.width * domainRow.share
      radius: Style.cornerRadius
      color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.12)
    }

    Text {
      id: domainText
      anchors.left: parent.left
      anchors.right: countText.left
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: domainRow.domain
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideMiddle
    }

    Caption {
      id: countText
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: root.compact(domainRow.queries)
    }
  }

  // Paste the key, press Enter. Shown until a working key is saved.
  component KeyEntry: Column {
    spacing: Style.space(6)

    TextField {
      id: keyField
      width: parent.width
      password: true
      enabled: !dns.keySaving
      placeholderText: dns.statsState === "auth" ? strings.t("key.rejected") : strings.t("key.placeholder")
      foreground: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      onTextChanged: dns.keyError = ""
      onAccepted: dns.saveKey(text)
      Keys.onEscapePressed: function(event) {
        if (text !== "") { text = ""; event.accepted = true }
        else event.accepted = false
      }
      Connections {
        target: dns
        // Forget the typed key once it has been handed over.
        function onKeySavingChanged() { if (!dns.keySaving && dns.keyError === "") keyField.text = "" }
      }
    }

    Caption {
      visible: dns.keyError !== ""
      width: parent.width
      text: dns.keyError !== "" ? strings.t(dns.keyError) : ""
      color: root.urgent
      wrapMode: Text.WordWrap
    }

    RowLayout {
      width: parent.width

      TextLink {
        text: strings.t("key.link") + "  󰏌"
        onClicked: root.openPage("account")
      }

      Item { Layout.fillWidth: true }

      TextLink {
        text: strings.t("key.dismiss")
        onClicked: root.setShowStats(false)
      }
    }
  }

  component TextLink: Caption {
    id: link
    signal clicked()
    color: linkMouse.containsMouse ? root.accent : root.dim
    font.underline: linkMouse.containsMouse

    MouseArea {
      id: linkMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: link.clicked()
    }
  }

  component LinkButton: PanelActionButton {
    property string glyph: ""
    property string page: ""
    property string tip: ""

    iconText: glyph
    tooltipText: tip
    foreground: root.dim
    hoverColor: root.foreground
    fontFamily: root.fontFamily
    Layout.alignment: Qt.AlignVCenter
    onClicked: root.openPage(page)
  }
}
