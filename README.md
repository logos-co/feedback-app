# feedback_ui

The Basecamp **Feedback app**: send feedback on Basecamp from inside Basecamp. Two forms, a quick
report (title, topic, message, optional contact) and a short questionnaire. Built with the Logos
design system; responsive at 390 / 700 / 1280.

Each response is sealed by **feedback_core** (anonymous `crypto_box_seal` to the Feedback Desk) and
published over **Logos Messaging**. The sender stays anonymous; only the Desk can open a response.

Part of a pair:
- **feedback-app** (this repo): the QML UI (`feedback_ui`).
- **feedback_core**: the C++ crypto core it depends on.

The always-on collector (Feedback Desk) and the design spec live in `xAlisher/feedback-bc`.

## Dependencies

- `feedback_core` (sealing)
- `delivery_module` (Logos Messaging)

## Deep link

Opens via the `feedback.open` intent carrying `{ topic }`, so the home "Share Feedback" tile (and
other apps) can open the app with a topic preselected.

## Files

- `Main.qml` — the view
- `metadata.json` / `manifest.json` — the `ui_qml` module descriptor (`pluginType: qml`)
- `feedback.png` — tile icon

## Notes

Today the UI talks to core modules directly from QML (`logos.callModule`). A planned follow-up moves
the connect/seal/send orchestration into `feedback_core` and exposes a single `submitFeedback()` to
QML, so the UI only calls its own backend. Tracked with the rest of the Feedback work in
logos-co/ecosystem#273.
