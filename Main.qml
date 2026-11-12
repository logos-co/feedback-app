// feedback_ui: send feedback on Basecamp. Two forms (quick + questionnaire); each response is
// sealed by feedback_core (crypto_box_seal to the Desk key) and published on the Logos Messaging
// testnet (logos.test, cluster 2) via delivery_module. A send counts only once delivery confirms it,
// and a node another app started on the wrong network or with RLN on is detected and explained
// (net.js). Built with the Logos design system; responsive at 390 / 700 / 1280.
import QtQuick 2.15
import QtQuick.Layouts 1.15
import QtQuick.LocalStorage 2.15
import Logos.Controls
import Logos.Theme
import "net.js" as Net

Rectangle {
    id: root
    objectName: "feedbackRoot"
    width: 420; height: 760
    color: Theme.palette.background

    // ---- config ----
    readonly property string quickTopic: "/logos-feedback/1/quick/json"
    readonly property string questTopic: "/logos-feedback/1/questionnaire/json"
    readonly property var topics: ["home","app","package-manager","node","wallet","delivery","messaging","onboarding","other"]
    readonly property string appBuild: "0.2.0"
    readonly property string nodeCfg: Net.nodeConfig()   // logos.test spelled out, no RLN send gate (#2)
    readonly property int confirmTimeoutMs: 60000

    // ---- responsive ----
    readonly property bool compact: width < 600
    readonly property int formW: Math.min(width - 2 * Theme.spacing.xlarge, 560)

    // ---- state ----
    property string connState: "connecting"   // connecting | ready  (gates Send)
    property string deliveryStatus: "starting" // raw delivery_module state for the honest status badge
    property string rlnState: ""               // delivery rlnState name ("" until read)
    // the node, as far as we can tell (#4)
    property bool adopted: false               // another app created the node: its config, not ours
    property int cluster: -1                   // from the node's ENR; 2 = logos.test
    property bool unconfirmed: false           // a send on a gated node got no confirmation
    property bool confirmedOnce: false         // delivery confirmed one of our sends on this node
    property string netState: "checking"       // ok | checking | wrongNetwork | rlnSuspect | rlnBlocked
    property string nodePeer: ""               // peer id of a node another app created (new per Basecamp run)
    property bool afterRestart: false          // we advised a restart, and it didn't help (#6)
    // sends waiting for delivery to confirm them (#3): requestId -> {payload, at}
    property var inflight: ({})
    property int inflightCount: 0
    property int unconfirmedCount: 0
    property string lastSend: ""               // sending | sent | saved | unconfirmed
    property int tab: 0                        // 0 quick, 1 questionnaire
    property bool sent: false
    property string note: ""
    property int qRating: 0
    property var pending: []
    property int pendingCount: 0

    function callMod(mod, method, params) {
        var raw = logos.callModule(mod, method, params || [])
        if (!raw || raw === "") return null
        try {
            var v = JSON.parse(raw)
            if (typeof v === "string") v = JSON.parse(v)  // host double-encodes a module's QString return
            return v
        } catch (e) { return { _raw: raw } }
    }

    // ---- deeplink: the home "Share Feedback" tile opens us via the feedback.open
    // intent carrying {topic}; preset the Quick-report dropdown to it. ----
    function presetTopic(t) {
        var i = root.topics.indexOf(t)
        if (i < 0) return
        root.sent = false
        root.tab = 0                 // Quick report
        qTopic.currentIndex = i      // the ComboBox is always instantiated (visible-toggled)
    }
    Connections {
        target: logos
        function onIntentRequested(requestId, intent, params, requesterName) {
            if (intent !== "feedback.open") return
            if (params && params.topic) root.presetTopic(String(params.topic))
            logos.respond(requestId, true, ({}), "")
        }
        // delivery's per-request outcome (#3); data[0] is the requestId send() returned
        function onModuleEventReceived(moduleName, eventName, data) {
            if (moduleName !== "delivery_module") return
            var id = data && data.length > 0 ? String(data[0]) : ""
            if (eventName === "messagePropagated" || eventName === "messageSent") root.confirm(id)
            else if (eventName === "messageError") root.failed(id, data && data.length > 2 ? String(data[2]) : "")
        }
    }

    // ---- delivery bring-up (adopt-or-create) + what kind of node we got (#4) ----
    function bringUp() {
        var c = Net.unwrap(callMod("delivery_module", "createNode", [root.nodeCfg]))
        if (!c.ok && Net.isAlreadyInitialized(c.error)) root.adopted = true   // someone else's config
        callMod("delivery_module", "start", [])
    }
    function reclassify() {
        root.netState = Net.classify({ adopted: root.adopted, cluster: root.cluster, rln: root.rlnState,
                                       unconfirmed: root.unconfirmed, confirmed: root.confirmedOnce })
        root.updateAdvice()
    }
    // Remember the node we told the user to restart away from; seeing a different one still blocked
    // means the restart didn't help, so stop advising it (#6).
    function updateAdvice() {
        var blocked = root.netState === "wrongNetwork" || root.netState === "rlnBlocked"
        if (!blocked) {
            if (root.netState === "ok") root._kvSet("adviceNode", "")
            root.afterRestart = false
            return
        }
        if (!root.nodePeer) return
        var advised = root._kvGet("adviceNode")
        if (Net.isLoop(advised, root.nodePeer)) root.afterRestart = true
        else if (!advised) root._kvSet("adviceNode", root.nodePeer)
    }
    Timer {
        interval: 1500; running: true; repeat: true
        onTriggered: {
            var cs = Net.unwrap(callMod("delivery_module", "getConnectionStatus", []))
            if (cs.value) root.deliveryStatus = String(cs.value)
            root.rlnState = Net.rlnStateName(Net.unwrap(callMod("delivery_module", "rlnState", [])).value)
            if (root.deliveryStatus.indexOf("Connected") >= 0 && root.deliveryStatus.indexOf("Disconnected") < 0) root.connState = "ready"
            if (root.cluster < 0 && root.connState === "ready")
                root.cluster = Net.clusterFromEnr(Net.unwrap(callMod("delivery_module", "getNodeInfo", ["MyENR"])).value)
            if (root.adopted && !root.nodePeer && root.connState === "ready")
                root.nodePeer = String(Net.unwrap(callMod("delivery_module", "getNodeInfo", ["MyPeerId"])).value || "")
            root.reclassify()
        }
    }
    Component.onCompleted: {
        if (typeof logos !== "undefined" && logos.onModuleEvent) {
            logos.onModuleEvent("delivery_module", "messagePropagated")
            logos.onModuleEvent("delivery_module", "messageSent")
            logos.onModuleEvent("delivery_module", "messageError")
        }
        bringUp(); loadQueue()
    }

    // ---- degraded-mode queue (local, persisted) + auto-retry ----
    function _db() {
        try { return LocalStorage.openDatabaseSync("feedback_ui_queue", "1.0", "feedback drafts", 200000) }
        catch (e) { return null }
    }
    function loadQueue() {
        var db = _db(); if (!db) return
        try { db.transaction(function(tx) {
            tx.executeSql("CREATE TABLE IF NOT EXISTS q(payload TEXT)")
            var rs = tx.executeSql("SELECT payload FROM q"); var arr = []
            for (var i = 0; i < rs.rows.length; i++) { try { arr.push(JSON.parse(rs.rows.item(i).payload)) } catch (e) {} }
            root.pending = arr; root.pendingCount = arr.length
        }) } catch (e) {}
    }
    function _kvGet(k) {
        var db = _db(); if (!db) return ""
        var v = ""
        try { db.transaction(function(tx) {
            tx.executeSql("CREATE TABLE IF NOT EXISTS kv(k TEXT PRIMARY KEY, v TEXT)")
            var rs = tx.executeSql("SELECT v FROM kv WHERE k = ?", [k])
            if (rs.rows.length > 0) v = rs.rows.item(0).v || ""
        }) } catch (e) {}
        return v
    }
    function _kvSet(k, v) {
        var db = _db(); if (!db) return
        try { db.transaction(function(tx) {
            tx.executeSql("CREATE TABLE IF NOT EXISTS kv(k TEXT PRIMARY KEY, v TEXT)")
            tx.executeSql("INSERT OR REPLACE INTO kv(k, v) VALUES(?, ?)", [k, v])
        }) } catch (e) {}
    }
    function saveQueue() {
        var db = _db(); if (!db) return
        try { db.transaction(function(tx) {
            tx.executeSql("CREATE TABLE IF NOT EXISTS q(payload TEXT)"); tx.executeSql("DELETE FROM q")
            for (var i = 0; i < root.pending.length; i++) tx.executeSql("INSERT INTO q VALUES(?)", [JSON.stringify(root.pending[i])])
        }) } catch (e) {}
    }
    // Send one response. Returns delivery's requestId, or "" when it can't go now (then it stays queued).
    function trySend(payload) {
        if (root.connState !== "ready" || !Net.canSend(root.netState)) return ""
        var sealed = callMod("feedback_core", "seal", [JSON.stringify(payload)])
        if (!sealed || !sealed.ok) return ""
        var topic = payload.kind === "questionnaire" ? root.questTopic : root.quickTopic
        var r = Net.unwrap(callMod("delivery_module", "send", [topic, sealed.ciphertext_b64]))
        if (!r.ok || !r.value) return ""
        var id = String(r.value), m = root.inflight
        m[id] = { payload: payload, at: Date.now() }
        root.inflight = m; root.inflightCount = Object.keys(m).length
        return id
    }
    function enqueue(payload) {
        root.pending.push(payload); root.pendingCount = root.pending.length; root.saveQueue()
    }
    function savedNote() {
        return Net.bannerText(root.netState, root.afterRestart) || ("Saved. It will send when messaging is ready (" + root.pendingCount + " queued).")
    }
    function submit(payload) {
        payload.v = 1; payload.ts = Date.now(); payload.build = root.appBuild
        root.sent = true
        if (root.trySend(payload)) { root.lastSend = "sending"; root.note = "" }
        else { root.enqueue(payload); root.lastSend = "saved"; root.note = root.savedNote() }
    }
    // delivery confirmed it: the message left this node
    function confirm(id) {
        var m = root.inflight
        if (!(id in m)) return
        delete m[id]; root.inflight = m; root.inflightCount = Object.keys(m).length
        root.confirmedOnce = true; root.unconfirmed = false; root.reclassify()
        if (root.lastSend === "sending" || root.lastSend === "unconfirmed") root.lastSend = "sent"
    }
    // delivery gave up on it: back to the queue, with the reason
    function failed(id, reason) {
        var m = root.inflight
        if (!(id in m)) return
        var p = m[id].payload
        delete m[id]; root.inflight = m; root.inflightCount = Object.keys(m).length
        root.enqueue(p)
        if (root.lastSend === "sending") { root.lastSend = "saved"; root.note = "Not sent (" + (reason || "delivery error") + "). Saved; it will retry." }
    }
    // No confirmation in time. On a node another app started with RLN on, the gate deferred it: it
    // never left, so queue it again. Otherwise it may still arrive; never resend it (the Desk would get
    // it twice), just say it isn't confirmed.
    function checkInflight() {
        var m = root.inflight, now = Date.now(), changed = false
        for (var id in m) {
            if (now - m[id].at < root.confirmTimeoutMs) continue
            var p = m[id].payload
            delete m[id]; changed = true
            if (root.adopted && Net.rlnGated(root.rlnState)) { root.enqueue(p); root.unconfirmed = true }
            else root.unconfirmedCount++
        }
        if (!changed) return
        root.inflight = m; root.inflightCount = Object.keys(m).length; root.reclassify()
        if (root.lastSend === "sending") {
            if (root.unconfirmed) { root.lastSend = "saved"; root.note = root.savedNote() }
            else root.lastSend = "unconfirmed"
        }
    }
    function flushQueue() {
        if (root.pending.length === 0 || root.connState !== "ready" || !Net.canSend(root.netState)) return
        if (root.netState === "rlnSuspect" && root.inflightCount > 0) return   // wait: is this node really sending?
        var still = []
        for (var i = 0; i < root.pending.length; i++) if (!root.trySend(root.pending[i])) still.push(root.pending[i])
        if (still.length !== root.pending.length) { root.pending = still; root.pendingCount = still.length; root.saveQueue() }
    }
    Timer { interval: 4000; running: true; repeat: true; onTriggered: { root.checkInflight(); root.flushQueue() } }

    // ---- UI ----
    LogosScrollView {
        anchors.fill: parent
        contentWidth: availableWidth

        ColumnLayout {
            width: root.formW
            x: Math.max(Theme.spacing.xlarge, (root.width - width) / 2)
            y: Theme.spacing.xlarge
            spacing: Theme.spacing.large

            // ── Header: title + description + honest delivery status badge (receiver-style) ──
            RowLayout {
                Layout.fillWidth: true; spacing: Theme.spacing.small
                ColumnLayout {
                    spacing: 0
                    LogosText {
                        text: "Feedback"
                        font.pixelSize: Theme.typography.panelTitleText
                        font.weight: Theme.typography.weightBold
                    }
                    LogosText {
                        text: "Share your feedback with the Basecamp team"
                        color: Theme.palette.textSecondary
                        font.pixelSize: Theme.typography.secondaryText
                        wrapMode: Text.WordWrap; Layout.fillWidth: true
                    }
                }
                Item { Layout.fillWidth: true }
                LogosBadge {
                    Layout.alignment: Qt.AlignVCenter
                    text:  (root.netState === "wrongNetwork" || root.netState === "rlnBlocked") ? "Can't send"
                         : root.deliveryStatus === "Connected"          ? "Delivery connected"
                         : root.deliveryStatus === "PartiallyConnected" ? "Delivery connecting…"
                         : root.deliveryStatus === "Disconnected"       ? "Delivery connecting…"
                         :                                                "Delivery starting…"
                    color: (root.netState === "wrongNetwork" || root.netState === "rlnBlocked") ? Theme.palette.error
                         : root.deliveryStatus === "Connected"          ? Theme.palette.success
                         : root.deliveryStatus === "PartiallyConnected" ? Theme.palette.warning
                         : root.deliveryStatus === "Disconnected"       ? Theme.palette.warning
                         :                                                Theme.palette.textSecondary
                }
            }

            // the node can't carry our feedback: say why and what to do (#4)
            Rectangle {
                Layout.fillWidth: true; radius: Theme.spacing.radiusSmall
                color: Theme.palette.surface; border.color: Theme.palette.error; border.width: 1
                Layout.preferredHeight: netT.implicitHeight + 2 * Theme.spacing.small
                visible: Net.bannerText(root.netState, root.afterRestart) !== null
                LogosText {
                    id: netT; objectName: "netBanner"
                    anchors.fill: parent; anchors.margins: Theme.spacing.small
                    wrapMode: Text.WordWrap; color: Theme.palette.error; font.pixelSize: 12
                    text: Net.bannerText(root.netState, root.afterRestart) || ""
                }
            }

            // degraded banner
            Rectangle {
                Layout.fillWidth: true; radius: Theme.spacing.radiusSmall
                color: Theme.palette.surface; border.color: Theme.palette.primary; border.width: 1
                Layout.preferredHeight: bannerT.implicitHeight + 2 * Theme.spacing.small
                visible: root.pendingCount > 0 || root.unconfirmedCount > 0
                LogosText {
                    id: bannerT; anchors.fill: parent; anchors.margins: Theme.spacing.small
                    wrapMode: Text.WordWrap; color: Theme.palette.primary; font.pixelSize: 12
                    text: "⏳ " + root.pendingCount + " saved, not sent yet." + (root.unconfirmedCount > 0 ? " " + root.unconfirmedCount + " sent but not confirmed." : "")
                }
            }

            // tabs — LogosTabBar owns the sliding indicator
            LogosTabBar {
                id: tabBar
                Layout.fillWidth: true; visible: !root.sent
                currentIndex: root.tab
                onCurrentIndexChanged: root.tab = currentIndex
                LogosTabButton { text: "Quick report" }
                LogosTabButton { text: "Questionnaire" }
            }

            // ---- Quick form ----
            ColumnLayout {
                Layout.fillWidth: true; spacing: Theme.spacing.medium
                visible: !root.sent && root.tab === 0
                LogosTextField { id: qTitle; Layout.fillWidth: true; placeholderText: "Title"
                    onTextChanged: if (text.length > 120) text = text.slice(0, 120) }
                LogosComboBox { id: qTopic; Layout.fillWidth: true; model: root.topics }
                LogosTextArea { id: qMsg; Layout.fillWidth: true; Layout.minimumHeight: 128
                    placeholderText: "What happened? What would you change?"
                    wrapMode: TextArea.Wrap
                    onTextChanged: if (text.length > 2000) text = text.slice(0, 2000) }
                LogosText { text: qMsg.text.length + " / 2000"; color: Theme.palette.textTertiary; font.pixelSize: 11; Layout.alignment: Qt.AlignRight }
                LogosTextField { id: qContact; Layout.fillWidth: true; placeholderText: "Contact (optional)"
                    onTextChanged: if (text.length > 200) text = text.slice(0, 200) }
                LogosText { text: "Only the Logos team can read your response."; color: Theme.palette.textTertiary; font.pixelSize: 11; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                LogosButton {
                    Layout.fillWidth: true; variant: LogosButton.Variant.Primary
                    text: "Send"
                    enabled: root.connState !== "connecting" && (qTitle.text.length > 0 || qMsg.text.length > 0)
                    onClicked: root.submit({ kind:"quick", title:qTitle.text, topic:root.topics[qTopic.currentIndex], message:qMsg.text, contact:qContact.text })
                }
            }

            // ---- Questionnaire ----
            ColumnLayout {
                Layout.fillWidth: true; spacing: Theme.spacing.large
                visible: !root.sent && root.tab === 1
                LogosText { text: "1. Rate Basecamp so far (1 poor – 5 great)"; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                RowLayout {
                    spacing: Theme.spacing.small
                    Repeater {
                        model: 5
                        LogosButton {
                            text: (index + 1); Layout.fillWidth: true
                            variant: root.qRating === index + 1 ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
                            onClicked: root.qRating = index + 1
                        }
                    }
                }
                QQ { id: a2; prompt: "2. What has Basecamp been useful for?" }
                QQ { id: a3; prompt: "3. Which modules/apps are you most excited about?" }
                QQ { id: a4; prompt: "4. One thing you'd improve right now?" }
                LogosButton {
                    Layout.fillWidth: true; variant: LogosButton.Variant.Primary
                    text: "Submit"
                    enabled: root.connState !== "connecting" && root.qRating > 0
                    onClicked: root.submit({ kind:"questionnaire", answers:{ q1:root.qRating, q2:a2.answer, q3:a3.answer, q4:a4.answer } })
                }
            }

            // ---- confirmation ----
            ColumnLayout {
                Layout.fillWidth: true; spacing: Theme.spacing.medium; visible: root.sent
                LogosText {
                    objectName: "sendState"
                    font.pixelSize: 18; wrapMode: Text.WordWrap; Layout.fillWidth: true
                    text: root.lastSend === "sent"        ? "Thanks, your feedback was sent."
                        : root.lastSend === "sending"     ? "Sending your feedback…"
                        : root.lastSend === "unconfirmed" ? "Sent, but not confirmed yet."
                        :                                   "Saved. Not sent yet."
                }
                LogosText { text: root.note; color: Theme.palette.textTertiary; font.pixelSize: 12; wrapMode: Text.WordWrap; Layout.fillWidth: true; visible: root.note.length > 0 }
                LogosButton { text: "Send another"; variant: LogosButton.Variant.Secondary
                    onClicked: { qTitle.text=""; qMsg.text=""; qContact.text=""; root.qRating=0; a2.answer=""; a3.answer=""; a4.answer=""; root.note=""; root.lastSend=""; root.sent=false } }
            }
        }
    }

    component QQ: ColumnLayout {
        id: qq
        property alias answer: ta.text
        property string prompt
        Layout.fillWidth: true; spacing: Theme.spacing.tiny
        LogosText { text: qq.prompt; wrapMode: Text.WordWrap; Layout.fillWidth: true }
        LogosTextArea { id: ta; Layout.fillWidth: true; Layout.minimumHeight: 76; wrapMode: TextArea.Wrap
            onTextChanged: if (text.length > 1000) text = text.slice(0, 1000) }
    }
}
