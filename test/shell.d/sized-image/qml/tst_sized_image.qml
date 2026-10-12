import QtQuick
import QtTest
import "../../../../shell/Ui"

// A SizedImage holds a bitmap no bigger than it is drawn, nor than its file,
// and places it the way PreserveAspectFit would.
Item {
  id: root
  width: 400
  height: 400

  // A 2560x1440 screenshot-sized file.
  readonly property url bigImage: Qt.resolvedUrl("../../../../themes/tokyo-night/preview.png")
  // A 400x10 strip.
  readonly property url narrowImage: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAZAAAAAKCAMAAACt6/hvAAAAA1BMVEX/AAAZ4gk3AAAAG0lEQVRIx+3BMQEAAADCoPVPbQ0PoAAAAIAfAw+qAAHXXPJgAAAAAElFTkSuQmCC"

  function bitmap(sized) {
    var image = sized.children[0]
    return { width: image.implicitWidth, height: image.implicitHeight }
  }

  function painted(sized) {
    var image = sized.children[0]
    return { x: image.x, y: image.y, width: image.width, height: image.height }
  }

  Image {
    id: native
    source: root.bigImage
  }

  SizedImage {
    id: thumbnail
    width: 40
    height: 40
    url: root.bigImage
  }

  SizedImage {
    id: strip
    width: 400
    height: 400
    verticalAlignment: Image.AlignTop
    url: root.narrowImage
  }

  SizedImage {
    id: unsized
    width: 0
    height: 40
    url: root.bigImage
  }

  TestCase {
    name: "SizedImage"
    when: windowShown

    function test_the_file_is_bigger_than_the_thumbnail() {
      tryCompare(native, "status", Image.Ready)
      compare(native.implicitWidth, 2560, "the fixture is full size")
    }

    function test_it_decodes_at_the_size_it_is_drawn() {
      tryCompare(thumbnail, "status", Image.Ready)
      var box = Math.ceil(40 * Screen.devicePixelRatio)
      var size = bitmap(thumbnail)
      compare(size.width, box, "the long side fits the box")
      verify(size.height < box, "and the short side keeps the aspect ratio: " + size.width + "x" + size.height)
      var rect = painted(thumbnail)
      compare(rect.width, 40, "drawn across the box")
      compare(rect.y, (40 - rect.height) / 2, "and centred in it")
    }

    function test_it_never_decodes_bigger_than_the_file() {
      tryCompare(strip, "status", Image.Ready)
      var size = bitmap(strip)
      compare(size.width, 400, "a strip narrower than the box keeps its width")
      compare(size.height, 10, "and its height")
      var rect = painted(strip)
      compare(rect.width, 400, "it is still drawn to fit the box")
      compare(rect.height, 10)
      compare(rect.y, 0, "at the top it was aligned to")
    }

    function test_it_waits_for_a_size_before_decoding() {
      wait(50)
      compare(unsized.status, Image.Null, "nothing decodes at native size first")
      unsized.width = 40
      tryCompare(unsized, "status", Image.Ready)
      verify(bitmap(unsized).width <= Math.ceil(40 * Screen.devicePixelRatio), "decoded width " + bitmap(unsized).width)
    }
  }
}
