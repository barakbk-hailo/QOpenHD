import QtQuick 2.12
import QtQuick.Controls 2.12
import QtQuick.Layouts 1.12
import QtQuick.Controls.Material 2.12

import OpenHD 1.0
import "../../elements"

/*
 * Dynamic settings panel for Hailo Drone-Follow parameters.
 *
 * Reads df_params.json from the local filesystem to discover what params
 * exist and their metadata (label, type, min/max/step, group, description).
 * The actual param values come from _ohdSystemAirSettingsModel via MAVLink.
 *
 * If df_params.json is not found, a fallback message is shown directing
 * the user to place the file.
 *
 * FLOAT params are scaled x100 in the MAVLink transport (e.g. kp_yaw 5.0
 * is stored as 500). The sliders show the real-world value; we
 * multiply/divide by 100 at the read/write boundary.
 */
Rectangle {
    id: root
    width: parent.width
    height: parent.height
    color: "#1a1a2e"

    property int rowHeight: 56

    // Track model updates - forces currentValue bindings to re-evaluate
    property int _uc: _ohdSystemAirSettingsModel.update_count

    // ── availability guard ──────────────────────────────────────────────
    property bool airAlive: _ohdSystemAir.is_alive
    property bool paramsReady: _ohdSystemAirSettingsModel.has_params_fetched

    // ── schema data ─────────────────────────────────────────────────────
    property var schema: null           // parsed JSON object
    property var groupList: []          // sorted array of {id, label}
    property var paramsByGroup: ({})    // group_id -> [param, ...]
    property bool schemaLoaded: false
    property string schemaError: ""

    // Whether any DF_ param exists in the air model
    property bool hailoAvailable: {
        if (!paramsReady || !schemaLoaded) return false;
        // Check if at least one schema param exists in the model
        var params = schema ? schema.params : [];
        for (var i = 0; i < params.length; ++i) {
            if (_ohdSystemAirSettingsModel.param_int_exists(params[i].mavlink_id))
                return true;
        }
        return false;
    }

    // ── parameter queue ────────────────────────────────────────────────
    property var _paramQueue: []

    function _enqueueParam(paramId, value) {
        for (var i = 0; i < _paramQueue.length; ++i) {
            if (_paramQueue[i].paramId === paramId) {
                _paramQueue[i].value = value;
                _paramQueue = _paramQueue;
                return;
            }
        }
        _paramQueue.push({paramId: paramId, value: value});
        _paramQueue = _paramQueue;
    }

    function _drainQueue() {
        if (_paramQueue.length === 0) return;
        if (_ohdSystemAirSettingsModel.ui_is_busy) return;
        var item = _paramQueue.shift();
        _paramQueue = _paramQueue;
        _ohdSystemAirSettingsModel.try_set_param_int_async(item.paramId, item.value, true);
    }

    property bool _modelBusy: _ohdSystemAirSettingsModel.ui_is_busy
    on_ModelBusyChanged: {
        if (!_modelBusy) _drainQueue();
    }

    property int _busyTicks: 0
    Timer {
        id: queueTimer
        interval: 500
        repeat: true
        running: _paramQueue.length > 0
        onTriggered: {
            if (_ohdSystemAirSettingsModel.ui_is_busy) {
                root._busyTicks++;
                if (root._busyTicks >= 10) {
                    console.log("DroneFollow: busy stuck for 5s, force-draining");
                    root._busyTicks = 0;
                    if (_paramQueue.length > 0) {
                        var item = _paramQueue.shift();
                        _paramQueue = _paramQueue;
                        _ohdSystemAirSettingsModel.try_set_param_int_async(
                            item.paramId, item.value, true);
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
        if (!_ohdSystemAirSettingsModel.param_int_exists(paramId)) return 0;
        return _ohdSystemAirSettingsModel.get_cached_int(paramId) / 100.0;
    }
    function setFloat(paramId, realValue) {
        if (!hailoAvailable) return;
        var intVal = Math.round(realValue * 100);
        _enqueueParam(paramId, intVal);
        _drainQueue();
    }
    function getInt(paramId) {
        if (!hailoAvailable) return 0;
        if (!_ohdSystemAirSettingsModel.param_int_exists(paramId)) return 0;
        return _ohdSystemAirSettingsModel.get_cached_int(paramId);
    }
    function setInt(paramId, value) {
        if (!hailoAvailable) return;
        _enqueueParam(paramId, value);
        _drainQueue();
    }
    function getBool(paramId) {
        if (!hailoAvailable) return false;
        if (!_ohdSystemAirSettingsModel.param_int_exists(paramId)) return false;
        return _ohdSystemAirSettingsModel.get_cached_int(paramId) !== 0;
    }
    function setBool(paramId, checked) {
        if (!hailoAvailable) return;
        var intVal = checked ? 1 : 0;
        _enqueueParam(paramId, intVal);
        _drainQueue();
    }

    // ── load schema at startup ──────────────────────────────────────────
    Component.onCompleted: loadSchema()

    function loadSchema() {
        var paths = [
            "file:///usr/local/share/openhd/df_params.json",
            "file:///home/pi/hailo-drone-follow/df_params.json"
        ];
        for (var i = 0; i < paths.length; ++i) {
            var xhr = new XMLHttpRequest();
            xhr.open("GET", paths[i], false);  // synchronous
            try {
                xhr.send();
            } catch (e) {
                continue;
            }
            if ((xhr.status === 200 || xhr.status === 0) && xhr.responseText.length > 10) {
                try {
                    var parsed = JSON.parse(xhr.responseText);
                    if (parsed && parsed.params && parsed.params.length > 0) {
                        buildSchema(parsed);
                        console.log("DroneFollow: loaded schema from " + paths[i] +
                                    " (" + parsed.params.length + " params)");
                        return;
                    }
                } catch (e2) {
                    schemaError = "Failed to parse df_params.json: " + e2;
                    console.warn("DroneFollow: " + schemaError);
                }
            }
        }
        schemaError = "df_params.json not found";
        console.warn("DroneFollow: " + schemaError);
    }

    function buildSchema(parsed) {
        schema = parsed;

        // Build sorted group list
        var groups = parsed.groups || [];
        groups.sort(function(a, b) { return (a.order || 0) - (b.order || 0); });
        var gl = [];
        var pbg = {};
        for (var g = 0; g < groups.length; ++g) {
            gl.push({id: groups[g].id, label: groups[g].label});
            pbg[groups[g].id] = [];
        }

        // Distribute params into groups (skip hidden ones)
        var params = parsed.params || [];
        for (var p = 0; p < params.length; ++p) {
            var param = params[p];
            if (param.hidden) continue;
            var gid = param.group || "other";
            if (!pbg[gid]) {
                gl.push({id: gid, label: gid.toUpperCase()});
                pbg[gid] = [];
            }
            pbg[gid].push(param);
        }

        // Sort params within each group
        for (var key in pbg) {
            pbg[key].sort(function(a, b) { return (a.order || 0) - (b.order || 0); });
        }

        // Remove empty groups
        var finalGl = [];
        for (var gi = 0; gi < gl.length; ++gi) {
            if (pbg[gl[gi].id] && pbg[gl[gi].id].length > 0) {
                finalGl.push(gl[gi]);
            }
        }

        groupList = finalGl;
        paramsByGroup = pbg;
        schemaLoaded = true;
    }

    // ── "not available" overlay ─────────────────────────────────────────
    Rectangle {
        anchors.fill: parent
        color: "#cc111122"
        z: 10
        visible: !airAlive || (!hailoAvailable && schemaLoaded)

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

    // ── "schema not found" overlay ──────────────────────────────────────
    Rectangle {
        anchors.fill: parent
        color: "#cc111122"
        z: 10
        visible: !schemaLoaded && airAlive

        Column {
            anchors.centerIn: parent
            spacing: 12
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "\uf15c"
                font.family: "Font Awesome 5 Free"
                font.pixelSize: 48
                color: "#ff8844"
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "df_params.json not found"
                color: "#cccccc"
                font.pixelSize: 16
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Place df_params.json in one of:\n" +
                      "  /usr/local/share/openhd/df_params.json\n" +
                      "  /home/pi/hailo-drone-follow/df_params.json\n\n" +
                      "This file is provided by the drone-follow package."
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
            }

            // ── Queue / busy status ─────────────────────────────────────
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: statusRow.width + 20
                height: statusRow.height + 8
                radius: 10
                color: root._modelBusy
                       ? "#33ff8800"
                       : (_paramQueue.length > 0 ? "#33ffcc00" : "transparent")
                visible: root._modelBusy || _paramQueue.length > 0

                Row {
                    id: statusRow
                    anchors.centerIn: parent
                    spacing: 8
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
                              ? "Sending\u2026"
                                + (_paramQueue.length > 0
                                   ? " (" + _paramQueue.length + " queued)" : "")
                              : _paramQueue.length + " queued"
                        color: "#bbbbbb"
                        font.pixelSize: 11
                    }
                }
            }

            // ── Schema version ──────────────────────────────────────────
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: schemaLoaded
                      ? (schema.params.length + " params from df_params.json v"
                         + (schema.version || "?"))
                      : ""
                color: "#555555"
                font.pixelSize: 10
                visible: schemaLoaded
            }

            Item { width: 1; height: 8 }

            // ── Dynamic sections ────────────────────────────────────────
            Repeater {
                model: root.groupList

                Column {
                    width: mainColumn.width
                    spacing: 4

                    property string groupId: modelData.id
                    property string groupLabel: modelData.label

                    // Section header
                    Rectangle {
                        width: parent.width
                        height: 32
                        color: "#22334455"
                        Text {
                            anchors.left: parent.left
                            anchors.leftMargin: 16
                            anchors.verticalCenter: parent.verticalCenter
                            text: groupLabel
                            color: "#66aaff"
                            font.pixelSize: 12
                            font.bold: true
                            font.letterSpacing: 1.5
                        }
                    }

                    // Params in this group
                    Repeater {
                        model: root.paramsByGroup[groupId] || []

                        Loader {
                            width: mainColumn.width
                            property var paramDef: modelData

                            sourceComponent: {
                                if (!paramDef) return null;
                                if (paramDef.read_only)
                                    return readOnlyComp;
                                if (paramDef.type === "bool")
                                    return switchComp;
                                if (paramDef.type === "float")
                                    return sliderComp;
                                return spinBoxComp;
                            }
                        }
                    }
                }
            }

            // ── bottom spacer ───────────────────────────────────────────
            Item { width: 1; height: 20 }
        }
    }

    // ════════════════════════════════════════════════════════════════════
    //  REUSABLE COMPONENTS
    // ════════════════════════════════════════════════════════════════════

    // ── Float slider ────────────────────────────────────────────────────
    Component {
        id: sliderComp

        Rectangle {
            id: sliderRoot
            width: parent ? parent.width : 100
            height: root.rowHeight + (sDescText.visible ? sDescText.height : 0)
            color: "transparent"

            property var pd: paramDef
            property real currentValue: {
                var dummy = root._uc;
                return root.getFloat(pd.mavlink_id);
            }
            property bool dirty: Math.abs(sSlider.value - currentValue) > ((pd.step || 0.1) * 0.1)

            onCurrentValueChanged: {
                if (!sSlider.pressed) sSlider.value = currentValue;
            }

            function sendValue() {
                root.setFloat(pd.mavlink_id, sSlider.value);
            }

            Timer {
                id: sSendTimer; interval: 800; repeat: false
                onTriggered: {
                    if (sliderRoot.dirty && !sSlider.pressed)
                        sliderRoot.sendValue();
                }
            }

            Column {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: 16

                RowLayout {
                    width: parent.width
                    Text {
                        text: sliderRoot.pd.label || sliderRoot.pd.mavlink_id
                        color: "#dddddd"; font.pixelSize: 14
                        Layout.fillWidth: true
                    }
                    Text {
                        text: "\u25cf"; color: "#ff8800"
                        font.pixelSize: 10; visible: sliderRoot.dirty
                    }
                    Text {
                        text: sSlider.value.toFixed(2)
                        color: sliderRoot.dirty ? "#ff8800" : "#66aaff"
                        font.pixelSize: 14; font.bold: true
                    }
                }

                Slider {
                    id: sSlider
                    width: parent.width
                    from: sliderRoot.pd.min !== undefined ? sliderRoot.pd.min : 0
                    to:   sliderRoot.pd.max !== undefined ? sliderRoot.pd.max : 100
                    stepSize: sliderRoot.pd.step || 0.1
                    value: sliderRoot.currentValue
                    live: true
                    onPressedChanged: {
                        if (!pressed) { sSendTimer.stop(); sliderRoot.sendValue(); }
                    }
                    onMoved: sSendTimer.restart()

                    background: Rectangle {
                        x: sSlider.leftPadding
                        y: sSlider.topPadding + sSlider.availableHeight / 2 - height / 2
                        implicitWidth: 200; implicitHeight: 4
                        width: sSlider.availableWidth; height: implicitHeight
                        radius: 2; color: "#333333"
                        Rectangle {
                            width: sSlider.visualPosition * parent.width
                            height: parent.height
                            color: sliderRoot.dirty ? "#cc6600" : "#3388cc"
                            radius: 2
                        }
                    }
                    handle: Rectangle {
                        x: sSlider.leftPadding
                           + sSlider.visualPosition * (sSlider.availableWidth - width)
                        y: sSlider.topPadding + sSlider.availableHeight / 2 - height / 2
                        implicitWidth: 18; implicitHeight: 18; radius: 9
                        color: sSlider.pressed ? "#55aaff"
                               : (sliderRoot.dirty ? "#cc6600" : "#3388cc")
                        border.color: "#222222"; border.width: 1
                    }
                }

                Text {
                    id: sDescText
                    width: parent.width
                    text: sliderRoot.pd.description || ""
                    color: "#666666"; font.pixelSize: 11
                    wrapMode: Text.WordWrap
                    visible: text.length > 0
                    topPadding: 2; bottomPadding: 4
                }
            }
        }
    }

    // ── Bool switch ─────────────────────────────────────────────────────
    Component {
        id: switchComp

        Rectangle {
            id: switchRoot
            width: parent ? parent.width : 100
            height: 52 + (swDescText.visible ? swDescText.height : 0)
            color: "transparent"

            property var pd: paramDef
            property bool currentValue: {
                var dummy = root._uc;
                return root.getBool(pd.mavlink_id);
            }
            onCurrentValueChanged: swSwitch.checked = currentValue

            RowLayout {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: 16

                Column {
                    Layout.fillWidth: true
                    Text {
                        text: switchRoot.pd.label || switchRoot.pd.mavlink_id
                        color: "#dddddd"; font.pixelSize: 14
                    }
                    Text {
                        id: swDescText
                        width: parent.width
                        text: switchRoot.pd.description || ""
                        color: "#666666"; font.pixelSize: 11
                        wrapMode: Text.WordWrap
                        visible: text.length > 0; topPadding: 2
                    }
                }

                Switch {
                    id: swSwitch
                    checked: switchRoot.currentValue
                    onClicked: root.setBool(switchRoot.pd.mavlink_id, checked)

                    indicator: Rectangle {
                        implicitWidth: 46; implicitHeight: 22
                        x: parent.leftPadding
                        y: parent.height / 2 - height / 2
                        radius: 11
                        color: parent.checked ? "#3388cc" : "#444444"
                        border.color: "#222222"
                        Rectangle {
                            x: parent.parent.checked ? parent.width - width - 3 : 3
                            y: 3
                            width: 16; height: 16; radius: 8
                            color: "#e0e0e0"
                            Behavior on x { NumberAnimation { duration: 120 } }
                        }
                    }
                }
            }
        }
    }

    // ── Read-only display ───────────────────────────────────────────────
    Component {
        id: readOnlyComp

        Rectangle {
            id: roRoot
            width: parent ? parent.width : 100
            height: 48
            color: "transparent"

            property var pd: paramDef
            property var currentValue: {
                var dummy = root._uc;
                if (pd.type === "float")
                    return root.getFloat(pd.mavlink_id);
                return root.getInt(pd.mavlink_id);
            }

            RowLayout {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: 16

                Column {
                    Layout.fillWidth: true
                    Text {
                        text: roRoot.pd.label || roRoot.pd.mavlink_id
                        color: "#dddddd"; font.pixelSize: 14
                    }
                    Text {
                        text: roRoot.pd.description || ""
                        color: "#666666"; font.pixelSize: 11
                        visible: text.length > 0
                    }
                }

                Text {
                    text: (roRoot.pd.type === "float")
                          ? Number(roRoot.currentValue).toFixed(2)
                          : roRoot.currentValue.toString()
                    color: roRoot.currentValue > 0 ? "#44cc88" : "#888888"
                    font.pixelSize: 18; font.bold: true
                }
            }
        }
    }

    // ── Int spin box ────────────────────────────────────────────────────
    Component {
        id: spinBoxComp

        Rectangle {
            id: sbRoot
            width: parent ? parent.width : 100
            height: 60 + (sbDescText.visible ? sbDescText.height : 0)
            color: "transparent"

            property var pd: paramDef
            property int currentValue: {
                var dummy = root._uc;
                return root.getInt(pd.mavlink_id);
            }
            onCurrentValueChanged: sbSpin.value = currentValue

            RowLayout {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: 16

                Column {
                    Layout.fillWidth: true
                    Text {
                        text: sbRoot.pd.label || sbRoot.pd.mavlink_id
                        color: "#dddddd"; font.pixelSize: 14
                    }
                    Text {
                        id: sbDescText
                        width: parent.width - sbSpin.width - 20
                        text: sbRoot.pd.description || ""
                        color: "#666666"; font.pixelSize: 11
                        wrapMode: Text.WordWrap
                        visible: text.length > 0; topPadding: 2
                    }
                }

                SpinBox {
                    id: sbSpin
                    from: sbRoot.pd.min !== undefined ? sbRoot.pd.min : 0
                    to:   sbRoot.pd.max !== undefined ? sbRoot.pd.max : 100
                    value: sbRoot.currentValue
                    editable: true
                    implicitWidth: 140
                    onValueModified: root.setInt(sbRoot.pd.mavlink_id, value)

                    background: Rectangle {
                        color: "#333333"; radius: 4
                        border.color: "#555555"
                    }
                    contentItem: TextInput {
                        text: sbSpin.textFromValue(sbSpin.value, sbSpin.locale)
                        color: "#e0e0e0"; font.pixelSize: 14
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        readOnly: !sbSpin.editable
                        validator: sbSpin.validator
                        inputMethodHints: Qt.ImhFormattedNumbersOnly
                    }
                }
            }
        }
    }
}
