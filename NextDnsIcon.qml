import QtQuick
import QtQuick.Shapes
import qs.Commons

// The NextDNS logo (a shield; path from Simple Icons, CC0) on the 24-unit grid
// of the bar's icons, painted in whatever colour the caller passes.
//   mark: "logo"  — the plain logo (all good)
//         "alert" — exclamation knocked out of the logo (something's off)
//         "off"   — outlined logo crossed by a slash (service stopped)
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property string mark: "logo"

  readonly property string logo: "M22.195 6.512l-.001-.019c-.01-.23-.017-.474-.022-.746a2.543 2.543 0 0 0-2.395-2.492c-2.759-.154-4.894-1.053-6.717-2.831l-.016-.015a1.536 1.536 0 0 0-2.087 0l-.016.015C9.117 2.202 6.982 3.101 4.223 3.256a2.543 2.543 0 0 0-2.395 2.492c-.004.269-.011.513-.022.745l-.001.044c-.053 2.813-.12 6.315 1.052 9.494.644 1.748 1.619 3.267 2.899 4.516 1.458 1.422 3.367 2.552 5.674 3.356.075.026.153.048.233.063a1.668 1.668 0 0 0 .675 0c.079-.015.158-.037.233-.063 2.305-.806 4.212-1.936 5.668-3.358 1.28-1.25 2.255-2.769 2.9-4.518 1.176-3.188 1.109-6.696 1.056-9.515Z"

  implicitWidth: iconSize
  implicitHeight: iconSize
  width: implicitWidth
  height: implicitHeight

  Shape {
    width: 24
    height: 24
    scale: root.width / 24
    transformOrigin: Item.TopLeft
    antialiasing: true
    layer.enabled: true
    layer.samples: 4

    // Filled logo; the exclamation is a second subpath, so OddEvenFill
    // punches it out and the bar background shows through.
    ShapePath {
      fillColor: root.mark === "off" ? "transparent" : root.color
      strokeWidth: -1
      fillRule: ShapePath.OddEvenFill
      PathSvg {
        path: root.logo + (root.mark === "alert" ? "M10.85 6H13.15V13.6H10.85ZM10.85 15.6H13.15V17.9H10.85Z" : "")
      }
    }

    ShapePath {
      fillColor: "transparent"
      strokeColor: root.mark === "off" ? root.color : "transparent"
      strokeWidth: 1.7
      capStyle: ShapePath.RoundCap
      joinStyle: ShapePath.RoundJoin
      PathSvg { path: root.logo + "M4.2 3.4L19.8 20.6" }
    }
  }
}
