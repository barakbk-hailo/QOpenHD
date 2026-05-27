import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.12

import QtQuick.Shapes 1.0
import QtQuick.Controls.Material 2.0

import Qt.labs.settings 1.0

import OpenHD 1.0

import "../elements"

SideBarBasePanel {
    override_title: "Ground recording"

    function takeover_control(){
        rec_button.forceActiveFocus();
    }

    Column {
        anchors.top: parent.top
        anchors.topMargin: secondaryUiHeight / 8 + 10
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: 10
        spacing: 8

        // --- Record toggle button ---
        Rectangle {
            width: parent.width
            height: 50
            radius: 6
            color: _groundRecordingManager.isRecording ? "#cc3333" : "#2d8c2d"

            MouseArea {
                id: rec_button
                anchors.fill: parent
                onClicked: _groundRecordingManager.toggleRecording()
            }

            Row {
                anchors.centerIn: parent
                spacing: 10
                Rectangle {
                    width: 16; height: 16; radius: 8
                    color: "white"
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !_groundRecordingManager.isRecording
                }
                Rectangle {
                    width: 14; height: 14; radius: 2
                    color: "white"
                    anchors.verticalCenter: parent.verticalCenter
                    visible: _groundRecordingManager.isRecording
                }
                Text {
                    text: _groundRecordingManager.isRecording ? "STOP RECORDING" : "START RECORDING"
                    font.pixelSize: 17; font.bold: true; color: "white"
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }

        // --- Elapsed time ---
        Rectangle {
            width: parent.width; height: 36; color: "#171d25"; radius: 4
            visible: _groundRecordingManager.isRecording
            Row {
                anchors.centerIn: parent; spacing: 8
                Rectangle {
                    id: blink_dot; width: 12; height: 12; radius: 6; color: "#ff3333"
                    anchors.verticalCenter: parent.verticalCenter
                    SequentialAnimation on opacity {
                        loops: Animation.Infinite
                        running: _groundRecordingManager.isRecording
                        NumberAnimation { to: 0.2; duration: 500 }
                        NumberAnimation { to: 1.0; duration: 500 }
                    }
                }
                Text {
                    text: "REC  " + _groundRecordingManager.elapsedTime
                    font.pixelSize: 18; font.family: "monospace"; color: "#ff5555"
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }

        // --- Status ---
        Rectangle {
            width: parent.width; height: 36; color: "#171d25"; radius: 4
            Text {
                anchors.centerIn: parent
                text: "Status: " + _groundRecordingManager.statusText
                font.pixelSize: 15; color: "white"
                elide: Text.ElideRight; width: parent.width - 16
                horizontalAlignment: Text.AlignHCenter
            }
        }

        // --- Last file ---
        Rectangle {
            width: parent.width; height: 36; color: "#171d25"; radius: 4
            visible: _groundRecordingManager.lastFileName.length > 0
            Text {
                anchors.centerIn: parent
                text: "Last: " + _groundRecordingManager.lastFileName
                font.pixelSize: 13; color: "#aaaaaa"
                elide: Text.ElideMiddle; width: parent.width - 16
                horizontalAlignment: Text.AlignHCenter
            }
        }

        // --- Embed & record options section ---
        Rectangle {
            width: parent.width; height: 1; color: "#333"
        }

        // Save HUD overlay toggle (recording-time — captures OSD to .osd file)
        Row {
            width: parent.width; spacing: 10
            Text {
                text: "Save HUD overlay"
                font.pixelSize: 14; color: "#cccccc"
                anchors.verticalCenter: parent.verticalCenter
            }
            Switch {
                checked: _groundRecordingManager.saveHud
                onToggled: _groundRecordingManager.saveHud = checked
                anchors.verticalCenter: parent.verticalCenter
            }
        }
        Text {
            width: parent.width
            text: "Embed via: embed_recording.py"
            font.pixelSize: 11; font.italic: true; color: "#888888"
            leftPadding: 4
        }

        // --- Recording count ---
        Rectangle {
            width: parent.width; height: 36; color: "#171d25"; radius: 4
            Text {
                anchors.centerIn: parent
                text: "Recordings: " + _groundRecordingManager.recordingCount + "  |  " + _groundRecordingManager.recordingDirectory()
                font.pixelSize: 13; color: "#aaaaaa"
                elide: Text.ElideRight; width: parent.width - 16
                horizontalAlignment: Text.AlignHCenter
            }
        }
    }
}
