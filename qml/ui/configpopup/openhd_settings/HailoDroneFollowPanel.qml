import QtQuick 2.12
import QtQuick.Controls 2.12
import QtQuick.Layouts 1.12
import QtQuick.Controls.Material 2.12

import OpenHD 1.0
import "../../elements"

/*
 * Dedicated settings panel for Hailo Drone-Follow parameters.
 *
 * All parameters live in the air unit's generic MAVLink param set
 * (_ohdSystemAirSettingsModel) under the "DF_" prefix.
 *
 * FLOAT params are scaled ×100 in the MAVLink transport (e.g. kp_yaw 5.0
 * is stored as 500). The sliders show the real-world value; we
 * multiply/divide by 100 at the read/write boundary.
 */
Rectangle {
    id: root
    width: parent.width
    height: parent.height
    color: "#1a1a2e"

    property int rowHeight: 56

    // Track model updates — incrementing this forces all currentValue bindings to re-evaluate
    property int _uc: _ohdSystemAirSettingsModel.update_count

    // ── availability guard ──────────────────────────────────────────────
    property bool airAlive: _ohdSystemAir.is_alive
    property bool paramsReady: _ohdSystemAirSettingsModel.has_params_fetched
    // Hailo params exist if DF_KP_YAW is present in the param set
    property bool hailoAvailable: paramsReady && _ohdSystemAirSettingsModel.param_int_exists("DF_KP_YAW")

    // ── parameter queue ────────────────────────────────────────────────
    // MavlinkSettingsModel.try_set_param_int_async() drops the call if
    // m_is_currently_busy is true (prints "BUSY" and reports failure).
    // Each set can be busy for up to 300 ms × 10 retries = 3 s, so
    // changing multiple sliders quickly causes silent drops.
    //
    // We queue pending changes and drain one-at-a-time when ui_is_busy
    // goes back to false.  If the same paramId is already in the queue,
    // we update its value in-place (only the latest matters).
    property var _paramQueue: []   // array of {paramId, value}

    function _enqueueParam(paramId, value) {
        // Coalesce: replace existing entry for same paramId
        for (var i = 0; i < _paramQueue.length; ++i) {
            if (_paramQueue[i].paramId === paramId) {
                _paramQueue[i].value = value;
                _paramQueue = _paramQueue; // trigger change signal
                return;
            }
        }
        _paramQueue.push({paramId: paramId, value: value});
        _paramQueue = _paramQueue; // trigger change signal
    }

    function _drainQueue() {
        if (_paramQueue.length === 0) return;
        if (_ohdSystemAirSettingsModel.ui_is_busy) return;
        var item = _paramQueue.shift();
        _paramQueue = _paramQueue; // trigger change signal
        _ohdSystemAirSettingsModel.try_set_param_int_async(item.paramId, item.value, true);
    }

    // Watch the busy flag — when it clears, send the next queued item
    property bool _modelBusy: _ohdSystemAirSettingsModel.ui_is_busy
    on_ModelBusyChanged: {
        if (!_modelBusy) _drainQueue();
    }

    // Track how long the model has been stuck busy
    property int _busyTicks: 0

    // Safety timer: poke the queue every 500ms in case a signal was missed.
    // Also detect permanently-stuck busy state (>5s = likely deadlocked)
    // and force-drain by calling try_set_param_int_async anyway.
    Timer {
        id: queueTimer
        interval: 500
        repeat: true
        running: _paramQueue.length > 0
        onTriggered: {
            if (_ohdSystemAirSettingsModel.ui_is_busy) {
                root._busyTicks++;
                if (root._busyTicks >= 10) {
                    // Busy for 5+ seconds — likely permanently stuck.
                    // Force-send the next item anyway
                    console.log("DroneFollow: busy stuck for 5s, force-draining queue");
                    root._busyTicks = 0;
                    if (_paramQueue.length > 0) {
                        var item = _paramQueue.shift();
                        _paramQueue = _paramQueue;
                        _ohdSystemAirSettingsModel.try_set_param_int_async(item.paramId, item.value, true);
                    }
                }
            } else {
                root._busyTicks = 0;
                root._drainQueue();
            }
        }
    }

    // ── helpers ─────────────────────────────────────────────────────────
    function getFloat(paramId) {
        if (!hailoAvailable) return 0;
        return _ohdSystemAirSettingsModel.get_cached_int(paramId) / 100.0;
    }
    function setFloat(paramId, realValue) {
        if (!hailoAvailable) return;
        var intVal = Math.round(realValue * 100);
        // Always go through queue to avoid BUSY drops and permanent-stuck issues
        _enqueueParam(paramId, intVal);
        _drainQueue();
    }
    function getInt(paramId) {
        if (!hailoAvailable) return 0;
        return _ohdSystemAirSettingsModel.get_cached_int(paramId);
    }
    function setInt(paramId, value) {
        if (!hailoAvailable) return;
        _enqueueParam(paramId, value);
        _drainQueue();
    }
    function getBool(paramId) {
        if (!hailoAvailable) return false;
        return _ohdSystemAirSettingsModel.get_cached_int(paramId) !== 0;
    }
    function setBool(paramId, checked) {
        if (!hailoAvailable) return;
        var intVal = checked ? 1 : 0;
        _enqueueParam(paramId, intVal);
        _drainQueue();
    }

    // ── "not available" overlay ─────────────────────────────────────────
    Rectangle {
        anchors.fill: parent
        color: "#cc111122"
        z: 10
        visible: !airAlive || !hailoAvailable

        Column {
            anchors.centerIn: parent
            spacing: 12
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: !airAlive ? "\uf071" : "\uf544"
                font.family: "Font Awesome 5 Free"
                font.pixelSize: 48
                color: "#ff8844"
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: !airAlive
                      ? "Air unit is not connected"
                      : "Hailo Drone-Follow is not active on the air unit"
                color: "#cccccc"
                font.pixelSize: 16
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: !airAlive
                      ? "Connect the air unit to configure drone-follow parameters."
                      : "Start 'drone-follow' on the air unit and restart OpenHD,\nor ensure the camera type is set to HAILO_AI."
                color: "#888888"
                font.pixelSize: 13
                horizontalAlignment: Text.AlignHCenter
            }
        }
    }

    // ── content ─────────────────────────────────────────────────────────
    Flickable {
        id: flickable
        anchors.fill: parent
        contentHeight: mainColumn.height + 40
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ScrollBar.vertical: ScrollBar {
            active: true
            policy: ScrollBar.AsNeeded
        }

        Column {
            id: mainColumn
            width: parent.width
            topPadding: 12
            spacing: 4

            // ── Header ──────────────────────────────────────────────────
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Hailo Drone-Follow"
                color: "#e0e0e0"
                font.pixelSize: 20
                font.bold: true
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Tune follow-me PID gains and behaviour"
                color: "#888888"
                font.pixelSize: 12
                bottomPadding: 4
            }

            // ── Queue / busy status ─────────────────────────────────────
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: statusRow.width + 20
                height: statusRow.height + 8
                radius: 10
                color: root._modelBusy ? "#33ff8800" : (_paramQueue.length > 0 ? "#33ffcc00" : "transparent")
                visible: root._modelBusy || _paramQueue.length > 0

                Row {
                    id: statusRow
                    anchors.centerIn: parent
                    spacing: 8

                    // Spinning indicator
                    Text {
                        text: "\u25cf"
                        color: root._modelBusy ? "#ff8800" : "#ffcc00"
                        font.pixelSize: 12
                        SequentialAnimation on opacity {
                            loops: Animation.Infinite
                            running: root._modelBusy
                            NumberAnimation { to: 0.3; duration: 400 }
                            NumberAnimation { to: 1.0; duration: 400 }
                        }
                    }

                    Text {
                        text: root._modelBusy
                              ? "Sending…" + (_paramQueue.length > 0 ? " (" + _paramQueue.length + " queued)" : "")
                              : _paramQueue.length + " queued"
                        color: "#bbbbbb"
                        font.pixelSize: 11
                    }
                }
            }

            // ════════════════════════════════════════════════════════════
            // SECTION: Yaw Control
            // ════════════════════════════════════════════════════════════
            SectionHeader { label: "YAW CONTROL" }

            ParamSlider {
                paramId: "DF_KP_YAW"
                label: "Yaw P-gain"
                description: "Proportional gain for yaw rotation towards the target"
                isFloat: true
                minVal: 0; maxVal: 20; stepVal: 0.1
            }

            ParamSlider {
                paramId: "DF_YAW_ALPHA"
                label: "Yaw smoothing (α)"
                description: "Low-pass filter coefficient — lower = smoother"
                isFloat: true
                minVal: 0.01; maxVal: 1.0; stepVal: 0.01
            }

            ParamSwitch {
                paramId: "DF_SMTH_YAW"
                label: "Smooth yaw"
                description: "Enable exponential smoothing on yaw commands"
            }

            ParamSwitch {
                paramId: "DF_YAW_ONLY"
                label: "Yaw only (no forward)"
                description: "Rotate towards the target but do not move forward/backward"
            }

            // ════════════════════════════════════════════════════════════
            // SECTION: Forward / Backward
            // ════════════════════════════════════════════════════════════
            SectionHeader { label: "FORWARD / BACKWARD" }

            ParamSlider {
                paramId: "DF_KP_FWD"
                label: "Forward P-gain"
                description: "Proportional gain for moving towards the target"
                isFloat: true
                minVal: 0; maxVal: 20; stepVal: 0.1
            }

            ParamSlider {
                paramId: "DF_KP_BACK"
                label: "Backward P-gain"
                description: "Proportional gain for reversing away when too close"
                isFloat: true
                minVal: 0; maxVal: 20; stepVal: 0.1
            }

            ParamSlider {
                paramId: "DF_MAX_FWD"
                label: "Max forward speed (m/s)"
                description: "Clamp forward velocity to this limit"
                isFloat: true
                minVal: 0; maxVal: 10; stepVal: 0.1
            }

            ParamSlider {
                paramId: "DF_MAX_BACK"
                label: "Max backward speed (m/s)"
                description: "Clamp backward velocity to this limit"
                isFloat: true
                minVal: 0; maxVal: 10; stepVal: 0.1
            }

            ParamSlider {
                paramId: "DF_FWD_ALPHA"
                label: "Forward smoothing (α)"
                description: "Low-pass filter coefficient for forward/backward commands"
                isFloat: true
                minVal: 0.01; maxVal: 1.0; stepVal: 0.01
            }

            ParamSwitch {
                paramId: "DF_SMTH_FWD"
                label: "Smooth forward"
                description: "Enable exponential smoothing on forward/backward commands"
            }

            // ════════════════════════════════════════════════════════════
            // SECTION: Target & Dead Zone
            // ════════════════════════════════════════════════════════════
            SectionHeader { label: "TARGET & DEAD ZONE" }

            ParamSlider {
                paramId: "DF_TGT_DIST"
                label: "Target distance (m)"
                description: "Desired follow distance in metres (0 = disabled — distance keeping off)"
                isFloat: true
                minVal: 0; maxVal: 50; stepVal: 0.5
            }

            ParamSlider {
                paramId: "DF_DZ_H_PCT"
                label: "Dead-zone height (%)"
                description: "Vertical dead-zone as a percentage of frame height. Target inside this zone → no movement."
                isFloat: true
                minVal: 0; maxVal: 50; stepVal: 0.5
            }

            // ════════════════════════════════════════════════════════════
            // SECTION: Flight
            // ════════════════════════════════════════════════════════════
            SectionHeader { label: "FLIGHT" }

            ParamSlider {
                paramId: "DF_TAKEOFF_M"
                label: "Takeoff altitude (m)"
                description: "Altitude used for automated takeoff"
                isFloat: true
                minVal: 1; maxVal: 20; stepVal: 0.5
            }

            ParamSwitch {
                paramId: "DF_FIX_ALT"
                label: "Fixed altitude"
                description: "When enabled, the drone maintains takeoff altitude and does not climb/descend"
            }

            // ════════════════════════════════════════════════════════════
            // SECTION: Tracking
            // ════════════════════════════════════════════════════════════
            SectionHeader { label: "TRACKING" }

            ParamReadOnly {
                paramId: "DF_ACTIVE_ID"
                label: "Active tracked ID"
                description: "Read-only — the person ID currently being followed (0 = none)"
            }

            ParamSpinBox {
                paramId: "DF_FOLLOW_ID"
                label: "Follow ID"
                description: "-1 = idle (hold position), 0 = auto (largest person), >0 = lock to specific ID"
                minVal: -1; maxVal: 999
            }

            // ════════════════════════════════════════════════════════════
            // SECTION: Video
            // ════════════════════════════════════════════════════════════
            SectionHeader { label: "VIDEO" }

            ParamSpinBox {
                paramId: "DF_BITRATE"
                label: "Bitrate (kbps)"
                description: "x264 encoder bitrate for the drone-follow video stream. Updated by variable-bitrate automatically."
                minVal: 500; maxVal: 20000
            }

            // ── bottom spacer ───────────────────────────────────────────
            Item { width: 1; height: 20 }
        }
    }

    // ════════════════════════════════════════════════════════════════════
    //  INLINE COMPONENTS
    // ════════════════════════════════════════════════════════════════════

    // ── Section header ──────────────────────────────────────────────────
    component SectionHeader: Rectangle {
        property string label: ""
        width: parent.width
        height: 32
        color: "#22334455"

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            text: label
            color: "#66aaff"
            font.pixelSize: 12
            font.bold: true
            font.letterSpacing: 1.5
        }
    }

    // ── Float/Int slider with label + value readout ─────────────────────
    component ParamSlider: Rectangle {
        id: paramSliderRoot
        property string paramId: ""
        property string label: ""
        property string description: ""
        property bool isFloat: false
        property real minVal: 0
        property real maxVal: 100
        property real stepVal: 1

        width: parent.width
        height: root.rowHeight + (descText.visible ? descText.height : 0)
        color: "transparent"

        // Depend on root._uc so this re-evaluates when the model updates
        property real currentValue: (root._uc * 0) + (isFloat ? root.getFloat(paramId) : root.getInt(paramId))

        // Track whether the slider value differs from the model value (unsent change)
        property bool dirty: Math.abs(slider.value - currentValue) > (stepVal * 0.1)

        // Re-set slider value when model pushes an update (binding breaks after user drag)
        onCurrentValueChanged: {
            if (!slider.pressed) {
                slider.value = currentValue;
            }
        }

        function sendCurrentSliderValue() {
            if (paramSliderRoot.isFloat) {
                root.setFloat(paramSliderRoot.paramId, slider.value);
            } else {
                root.setInt(paramSliderRoot.paramId, Math.round(slider.value));
            }
        }

        // Debounce timer — fires 800ms after last movement as fallback
        // in case onPressedChanged doesn't fire (e.g. touch input quirks)
        Timer {
            id: sendTimer
            interval: 800
            repeat: false
            onTriggered: {
                if (paramSliderRoot.dirty && !slider.pressed) {
                    paramSliderRoot.sendCurrentSliderValue();
                }
            }
        }

        Column {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: 16

            // Row 1: label + value + dirty indicator
            RowLayout {
                width: parent.width
                Text {
                    text: paramSliderRoot.label
                    color: "#dddddd"
                    font.pixelSize: 14
                    Layout.fillWidth: true
                }
                // Unsent indicator
                Text {
                    text: "\u25cf"
                    color: "#ff8800"
                    font.pixelSize: 10
                    visible: paramSliderRoot.dirty
                }
                Text {
                    text: paramSliderRoot.isFloat ? slider.value.toFixed(2) : Math.round(slider.value).toString()
                    color: paramSliderRoot.dirty ? "#ff8800" : "#66aaff"
                    font.pixelSize: 14
                    font.bold: true
                    horizontalAlignment: Text.AlignRight
                }
            }

            // Row 2: slider
            Slider {
                id: slider
                width: parent.width
                from: paramSliderRoot.minVal
                to: paramSliderRoot.maxVal
                stepSize: paramSliderRoot.stepVal
                value: paramSliderRoot.currentValue
                live: true

                // Primary: send on release
                onPressedChanged: {
                    if (!pressed) {
                        sendTimer.stop();
                        paramSliderRoot.sendCurrentSliderValue();
                    }
                }

                // Backup: restart debounce timer on any movement
                onMoved: {
                    sendTimer.restart();
                }

                background: Rectangle {
                    x: slider.leftPadding
                    y: slider.topPadding + slider.availableHeight / 2 - height / 2
                    implicitWidth: 200
                    implicitHeight: 4
                    width: slider.availableWidth
                    height: implicitHeight
                    radius: 2
                    color: "#333333"

                    Rectangle {
                        width: slider.visualPosition * parent.width
                        height: parent.height
                        color: paramSliderRoot.dirty ? "#cc6600" : "#3388cc"
                        radius: 2
                    }
                }

                handle: Rectangle {
                    x: slider.leftPadding + slider.visualPosition * (slider.availableWidth - width)
                    y: slider.topPadding + slider.availableHeight / 2 - height / 2
                    implicitWidth: 18
                    implicitHeight: 18
                    radius: 9
                    color: slider.pressed ? "#55aaff" : (paramSliderRoot.dirty ? "#cc6600" : "#3388cc")
                    border.color: "#222222"
                    border.width: 1
                }
            }

            // Row 3: description
            Text {
                id: descText
                width: parent.width
                text: paramSliderRoot.description
                color: "#666666"
                font.pixelSize: 11
                wrapMode: Text.WordWrap
                visible: paramSliderRoot.description.length > 0
                topPadding: 2
                bottomPadding: 4
            }
        }
    }

    // ── Boolean switch ──────────────────────────────────────────────────
    component ParamSwitch: Rectangle {
        id: paramSwitchRoot
        property string paramId: ""
        property string label: ""
        property string description: ""

        width: parent.width
        height: 52 + (switchDescText.visible ? switchDescText.height : 0)
        color: "transparent"

        // Depend on root._uc so this re-evaluates when the model updates
        property bool currentValue: (root._uc >= 0) && root.getBool(paramId)

        onCurrentValueChanged: paramSwitch.checked = currentValue

        RowLayout {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: 16

            Column {
                Layout.fillWidth: true
                Text {
                    text: paramSwitchRoot.label
                    color: "#dddddd"
                    font.pixelSize: 14
                }
                Text {
                    id: switchDescText
                    width: parent.width
                    text: paramSwitchRoot.description
                    color: "#666666"
                    font.pixelSize: 11
                    wrapMode: Text.WordWrap
                    visible: paramSwitchRoot.description.length > 0
                    topPadding: 2
                }
            }

            Switch {
                id: paramSwitch
                checked: paramSwitchRoot.currentValue
                onClicked: {
                    root.setBool(paramSwitchRoot.paramId, checked);
                }

                indicator: Rectangle {
                    implicitWidth: 46
                    implicitHeight: 22
                    x: parent.leftPadding
                    y: parent.height / 2 - height / 2
                    radius: 11
                    color: parent.checked ? "#3388cc" : "#444444"
                    border.color: "#222222"

                    Rectangle {
                        x: parent.parent.checked ? parent.width - width - 3 : 3
                        y: 3
                        width: 16
                        height: 16
                        radius: 8
                        color: "#e0e0e0"
                        Behavior on x { NumberAnimation { duration: 120 } }
                    }
                }
            }
        }
    }

    // ── Read-only integer display ───────────────────────────────────────
    component ParamReadOnly: Rectangle {
        id: paramReadOnlyRoot
        property string paramId: ""
        property string label: ""
        property string description: ""

        width: parent.width
        height: 48
        color: "transparent"

        // Depend on root._uc so this re-evaluates when the model updates
        property int currentValue: (root._uc * 0) + root.getInt(paramId)

        RowLayout {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: 16

            Column {
                Layout.fillWidth: true
                Text {
                    text: paramReadOnlyRoot.label
                    color: "#dddddd"
                    font.pixelSize: 14
                }
                Text {
                    text: paramReadOnlyRoot.description
                    color: "#666666"
                    font.pixelSize: 11
                    visible: paramReadOnlyRoot.description.length > 0
                }
            }

            Text {
                text: paramReadOnlyRoot.currentValue.toString()
                color: paramReadOnlyRoot.currentValue > 0 ? "#44cc88" : "#888888"
                font.pixelSize: 18
                font.bold: true
            }
        }
    }

    // ── Integer spin box ────────────────────────────────────────────────
    component ParamSpinBox: Rectangle {
        id: paramSpinBoxRoot
        property string paramId: ""
        property string label: ""
        property string description: ""
        property int minVal: 0
        property int maxVal: 100

        width: parent.width
        height: 60 + (spinDescText.visible ? spinDescText.height : 0)
        color: "transparent"

        // Depend on root._uc so this re-evaluates when the model updates
        property int currentValue: (root._uc * 0) + root.getInt(paramId)

        onCurrentValueChanged: spinBox.value = currentValue

        RowLayout {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: 16

            Column {
                Layout.fillWidth: true
                Text {
                    text: paramSpinBoxRoot.label
                    color: "#dddddd"
                    font.pixelSize: 14
                }
                Text {
                    id: spinDescText
                    width: parent.width - spinBox.width - 20
                    text: paramSpinBoxRoot.description
                    color: "#666666"
                    font.pixelSize: 11
                    wrapMode: Text.WordWrap
                    visible: paramSpinBoxRoot.description.length > 0
                    topPadding: 2
                }
            }

            SpinBox {
                id: spinBox
                from: paramSpinBoxRoot.minVal
                to: paramSpinBoxRoot.maxVal
                value: paramSpinBoxRoot.currentValue
                editable: true
                implicitWidth: 140

                onValueModified: {
                    root.setInt(paramSpinBoxRoot.paramId, value);
                }

                background: Rectangle {
                    color: "#333333"
                    radius: 4
                    border.color: "#555555"
                }

                contentItem: TextInput {
                    text: spinBox.textFromValue(spinBox.value, spinBox.locale)
                    color: "#e0e0e0"
                    font.pixelSize: 14
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    readOnly: !spinBox.editable
                    validator: spinBox.validator
                    inputMethodHints: Qt.ImhFormattedNumbersOnly
                }
            }
        }
    }
}
