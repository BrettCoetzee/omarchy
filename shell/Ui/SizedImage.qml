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

  Image {
    id: image

    readonly property real fitScale: implicitWidth > 0 && implicitHeight > 0
      ? Math.min(root.width / implicitWidth, root.height / implicitHeight) : 0

    width: implicitWidth * fitScale
    height: implicitHeight * fitScale
    x: root.horizontalAlignment === Image.AlignLeft ? 0
      : root.horizontalAlignment === Image.AlignRight ? root.width - width
      : (root.width - width) / 2
    y: root.verticalAlignment === Image.AlignTop ? 0
      : root.verticalAlignment === Image.AlignBottom ? root.height - height
      : (root.height - height) / 2

    source: root.sized ? root.url : ""
    sourceSize.width: root.sized ? Math.ceil(root.width * Screen.devicePixelRatio) : 0
    sourceSize.height: root.sized ? Math.ceil(root.height * Screen.devicePixelRatio) : 0
    fillMode: Image.Stretch
    asynchronous: root.asynchronous
    smooth: root.smooth
  }
}
