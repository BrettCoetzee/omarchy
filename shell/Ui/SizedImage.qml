import QtQuick

// An image fitted inside this item, preserving its aspect ratio, and decoded
// at the size it is drawn, in physical pixels, instead of at the file's own
// size. A 2560x1440 screenshot shown as a 40px thumbnail would otherwise hold
// a 14 MB bitmap for as long as the thumbnail exists.
//
// The inner Image is not PreserveAspectFit on purpose. With PreserveAspectFit
// Qt scales the decode to cover sourceSize, which upscales an image narrower
// than the box: a 400x10 strip in a 400x400 box would decode at 16000x400.
// Without it, sourceSize is a bound Qt only ever shrinks the image to fit, so
// the bitmap is never larger than the box or the file. This item then places
// the decoded image the way PreserveAspectFit would.
//
// That only holds for raster images. Qt renders an SVG at exactly sourceSize
// when the fill mode is not a preserving one, which would stretch it, and with
// PreserveAspectFit it covers the box like any other image. An SVG therefore
// keeps Qt's own handling: rendered at its intrinsic size and fitted on draw.
//
// The image waits until the item has been laid out, so nothing is decoded at
// native size first.
Item {
  id: root

  property url url: ""
  property int horizontalAlignment: Image.AlignHCenter
  property int verticalAlignment: Image.AlignVCenter
  property bool asynchronous: true
  readonly property alias status: image.status
  readonly property bool sized: width > 0 && height > 0
  // Clipboard captures name the file after the MIME subtype, as in .svg+xml.
  readonly property bool scalable: /(\.svg[^/]*|^data:image\/svg[^,]*,.*)$/i.test(String(url))

  Image {
    id: image

    readonly property real fitScale: implicitWidth > 0 && implicitHeight > 0
      ? Math.min(root.width / implicitWidth, root.height / implicitHeight) : 0

    width: root.scalable ? root.width : implicitWidth * fitScale
    height: root.scalable ? root.height : implicitHeight * fitScale
    x: root.scalable || root.horizontalAlignment === Image.AlignLeft ? 0
      : root.horizontalAlignment === Image.AlignRight ? root.width - width
      : (root.width - width) / 2
    y: root.scalable || root.verticalAlignment === Image.AlignTop ? 0
      : root.verticalAlignment === Image.AlignBottom ? root.height - height
      : (root.height - height) / 2

    source: root.sized ? root.url : ""
    sourceSize.width: root.sized && !root.scalable ? Math.ceil(root.width * Screen.devicePixelRatio) : 0
    sourceSize.height: root.sized && !root.scalable ? Math.ceil(root.height * Screen.devicePixelRatio) : 0
    fillMode: root.scalable ? Image.PreserveAspectFit : Image.Stretch
    horizontalAlignment: root.horizontalAlignment
    verticalAlignment: root.verticalAlignment
    asynchronous: root.asynchronous
    smooth: root.smooth
  }
}
