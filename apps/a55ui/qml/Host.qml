import QtQuick 2.3

// Plays the part of the A55's framework/FrameWork.qml for one screen at a time.
//
// The Sony screens and window chrome are written for a 480-px-wide display and
// read several names through QML's dynamic scope: viewstyle and screen_info
// from the root object of the file that holds their Loader (this file), and
// controller / viewModel from the Loader itself. This file therefore keeps the
// same shape as FrameWork.qml: those two objects are properties of the root,
// and the screen and window are loaded by Loaders placed directly in it.
//
// Everything lives on a "stage" of 480 x N logical px that is scaled up to the
// display width, so a 720-px-wide panel shows the A55 layout at 1.5x. N is the
// display height at that scale (853 on 720x1280); the A55 itself is 480x800.
//
// A screen spec (screens/*.json) names the screen and window QML, the values
// the ViewModel would push into them, and the screen area the window leaves.
Rectangle {
    id: host
    color: "black"
    focus: true

    readonly property int baseWidth: 480
    readonly property real zoom: width / baseWidth
    readonly property int baseHeight: Math.round(height / zoom)

    property int current: -1
    property var spec: current >= 0 ? a55Screens[current] : ({})
    property var history: []

    // Simulated player state, shared by every screen that shows it. The track
    // is the one in screens/player.json; the position just counts up.
    property bool playing: false
    property real positionMs: 62000
    readonly property real durationMs: 253000

    property QtObject viewstyle: QtObject {
        property string mode: "normal"
        property string empty_string: appFont.emptyString
        property string font_family: appFont.fontFamily
        property string language_name: appFont.language_name
        property var textsize: screenController.styleProperties[mode]["textsize"]
        property var textcolor: screenController.styleProperties[mode]["textcolor"]
        property var bgcolor: screenController.styleProperties[mode]["bgcolor"]
    }

    property QtObject screen_info: QtObject {
        readonly property var inset: host.spec.inset || ({top: 44, bottom: 0})
        property real window_width: host.baseWidth
        property real window_height: host.baseHeight
        property real width: host.baseWidth
        property real height: host.baseHeight - inset.top - inset.bottom
        property real x: 0
        property real y: inset.top
    }

    // The stubs are the app's own idea of the window; keep them in step.
    onBaseHeightChanged: syncController()
    function syncController() {
        screenController.windowWidth = baseWidth
        screenController.windowHeight = baseHeight
        screenController.width = screen_info.width
        screenController.height = screen_info.height
        screenController.y = screen_info.y
    }

    // ---- helpers ----------------------------------------------------------

    // Like FrameWork.qml's Binding-based binder: only ever writes the view's
    // own properties.
    function apply(item, values) {
        for (var name in values) {
            if (name in item)
                item[name] = values[name]
            else
                console.warn("a55ui: " + item + " has no property " + name)
        }
    }

    function findChild(item, name) {
        if (!item)
            return null
        if (item.objectName === name)
            return item
        var kids = item.children || []
        for (var i = 0; i < kids.length; ++i) {
            var hit = findChild(kids[i], name)
            if (hit)
                return hit
        }
        return null
    }

    function indexOfId(id) {
        for (var i = 0; i < a55Screens.length; ++i)
            if (a55Screens[i].id === id)
                return i
        return -1
    }

    // Deep copy so a spec's constants stay constant. QObjects (the stub models)
    // are kept as they are; a JSON round trip would flatten them.
    function clone(value) {
        if (value === null || typeof value !== "object")
            return value
        if (typeof value.objectNameChanged === "function")
            return value
        var out = Array.isArray(value) ? [] : {}
        for (var k in value)
            out[k] = clone(value[k])
        return out
    }

    // ---- navigation -------------------------------------------------------

    function go(id, remember) {
        var i = indexOfId(id)
        if (i < 0 || i === current)
            return
        if (remember !== false && current >= 0)
            history = history.concat([a55Screens[current].id])
        show(i)
    }

    function back() {
        if (history.length === 0)
            return
        var id = history[history.length - 1]
        history = history.slice(0, history.length - 1)
        show(indexOfId(id))
    }

    function show(i) {
        picker.visible = false
        current = i
        syncController()
        screenLoader.active = false
        windowLoader.active = false
        screenLoader.source = spec.screen || ""
        windowLoader.source = spec.window || ""
        screenLoader.active = true
        windowLoader.active = true
        host.forceActiveFocus()
    }

    // Values for the window chrome, with the simulated transport state.
    function windowValues() {
        var v = clone(spec.windowValues || {})
        if (v.basicPlayerControls)
            v.basicPlayerControls.playState = playing
        return v
    }

    function wireWindow(win) {
        var nav = findChild(win, "navigationBar")
        if (nav) {
            nav.back.connect(function() { host.back() })
            nav.play.connect(function() { host.go("player") })
            nav.library.connect(function() { host.go("home") })
            // The A55 opens an option menu dialog here, which needs the app's
            // DialogManager; until that is stubbed, the Settings screen is the
            // useful thing behind the button. (The menu's own handler still runs.)
            var option = findChild(nav, "OptionButton")
            if (option)
                option.clicked.connect(function() { host.go("settings") })
        }
        var ctl = findChild(win, "basicPlayerControls")
        if (ctl) {
            ctl.playButtonClicked.connect(function() { host.playing = !host.playing })
            ctl.prevButtonClicked.connect(function() { host.positionMs = 0 })
            ctl.nextButtonClicked.connect(function() { host.positionMs = 0 })
        }
    }

    onPlayingChanged: {
        if (windowLoader.item)
            apply(windowLoader.item, {basicPlayerControls: windowValues().basicPlayerControls})
    }

    Component.onCompleted: {
        var i = indexOfId(a55Initial)
        show(i >= 0 ? i : 0)
    }

    // Back steps back through the screens visited; at the start it opens the list.
    // Called from the window (main.cpp), so it works wherever the focus is.
    function handleBack() {
        if (picker.visible)
            picker.visible = false
        else if (history.length > 0)
            back()
        else
            picker.visible = true
    }

    // Advance the fake play position once a second while "playing".
    Timer {
        interval: 1000
        repeat: true
        running: host.playing
        onTriggered: host.positionMs = host.positionMs + 1000 >= host.durationMs
                     ? 0 : host.positionMs + 1000
    }

    onPositionMsChanged: {
        var item = screenLoader.item
        if (item && "currently_playing_time" in item)
            item.currently_playing_time = positionMs
    }

    // ---- the A55 display, scaled to the panel ---------------------------

    Item {
        id: stage
        width: host.baseWidth
        height: host.baseHeight
        scale: host.zoom
        transformOrigin: Item.TopLeft

        Rectangle {
            anchors.fill: parent
            color: viewstyle.bgcolor.D1
        }

        Loader {
            id: screenLoader
            active: false
            // FrameWork.qml's screen loaders carry these; screens reach them
            // through dynamic scope.
            property QtObject controller: screenController
            property QtObject viewModel
            x: screen_info.x
            y: screen_info.y
            width: screen_info.width
            height: screen_info.height
            onLoaded: {
                item.visible = true
                host.apply(item, host.clone(host.spec.values || {}))
                if ("currently_playing_time" in item)
                    item.currently_playing_time = host.positionMs
                if (host.spec.available)
                    controller.available(null)
            }
            onStatusChanged: if (status === Loader.Error)
                console.warn("a55ui: screen failed to load: " + source)
        }

        Loader {
            id: windowLoader
            active: false
            anchors.fill: parent
            onLoaded: {
                host.apply(item, host.windowValues())
                host.wireWindow(item)
            }
            onStatusChanged: if (status === Loader.Error)
                console.warn("a55ui: window failed to load: " + source)
        }
    }

    // ---- developer chrome: screen picker ----------------------------------
    // A tab on the right edge and the Android Back key both open the list.

    Rectangle {
        id: tab
        z: 50
        width: 22 * host.zoom
        height: 76 * host.zoom
        x: host.width - width
        y: host.height * 0.18
        radius: 8 * host.zoom
        color: "#59ffffff"
        visible: !picker.visible
        Text {
            anchors.centerIn: parent
            text: "‹"
            color: "black"
            font.pixelSize: 36 * host.zoom
        }
        MouseArea {
            anchors.fill: parent
            anchors.margins: -10
            onClicked: picker.visible = true
        }
    }

    Rectangle {
        id: picker
        z: 60
        anchors.fill: parent
        visible: false
        color: "#f2000000"

        MouseArea { anchors.fill: parent; onClicked: picker.visible = false }

        Column {
            anchors.centerIn: parent
            width: parent.width * 0.86
            spacing: 14 * host.zoom

            Text {
                text: "A55 screens"
                color: "#98ffffff"
                font.pixelSize: 22 * host.zoom
            }

            Repeater {
                model: a55Screens
                Rectangle {
                    width: parent.width
                    height: 54 * host.zoom
                    radius: 6 * host.zoom
                    color: index === host.current ? "#00ccff" : "#262626"
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        x: 18 * host.zoom
                        text: modelData.title
                        color: index === host.current ? "black" : "white"
                        font.pixelSize: 24 * host.zoom
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            host.history = []
                            host.show(index)
                        }
                    }
                }
            }
        }
    }
}
