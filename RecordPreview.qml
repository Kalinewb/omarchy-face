import QtQuick
import QtMultimedia

// The mirrored RGB preview inside the recording card (plan-gui.md §5.3).
//
// It is a file of its own, loaded through a Loader, for one reason: `import
// QtMultimedia` is a hard failure for the whole file on a machine whose Qt has
// no multimedia module. Isolated here, that failure is a Loader in the Error
// state and the card falls back to the plain oval with "No preview on this
// laptop"; inlined in the card, it would be a recording card that does not load.
//
// This is a preview and nothing else. The face that gets recorded is taken by
// howdy from the *infrared* sensor, which the session opens only on `capture`;
// nothing here ever touches that device.
Item {
  id: preview

  // The RGB node from `camera.rgb`, e.g. /dev/video0.
  property string device: ""

  // An instance, not the type name. MediaDevices is an ordinary object type in
  // Qt 6, not a singleton: `MediaDevices.videoInputs` read off the type is
  // undefined, so `chosen` threw on every evaluation and the card never had a
  // camera to show -- the preview stayed blank on every laptop, with two
  // warnings in the journal each time a card opened.
  MediaDevices { id: mediaDevices }

  readonly property var chosen: {
    var devices = mediaDevices.videoInputs
    for (var i = 0; i < devices.length; i++) {
      // Qt's V4L2 backend uses the device node as the id.
      if (String(devices[i].id) === preview.device) return devices[i]
    }
    return null
  }

  CaptureSession {
    id: capture
    camera: Camera {
      id: camera
      cameraDevice: preview.chosen ? preview.chosen : mediaDevices.defaultVideoInput
      active: preview.visible && preview.chosen !== null
    }
    videoOutput: output
  }

  VideoOutput {
    id: output
    anchors.fill: parent
    fillMode: VideoOutput.PreserveAspectCrop
    // Mirrored, because a preview that moves the other way from your head is
    // harder to centre a face in than no preview at all.
    transform: Scale { xScale: -1; origin.x: output.width / 2 }
  }
}
