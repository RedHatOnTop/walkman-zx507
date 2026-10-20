// Never loaded. androiddeployqt scans this directory for QML imports to decide
// which Qt QML modules go into the APK; the Sony stock UI imports these from
// inside stock.rcc, which the scanner cannot see. Versions are the highest the
// Sony QML uses.
import QtQuick 2.3
import QtQuick.Window 2.2
import QtQuick.Controls 1.2
import QtQuick.Controls.Styles 1.2
import QtQuick.Dialogs 1.2
import QtQml.Models 2.1
import QtGraphicalEffects 1.0

Item {}
