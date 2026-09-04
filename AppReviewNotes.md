# App Review Notes

PocketMai voice capture is user-started only. To review locked-screen voice chat:

1. Open Settings > Look and Feel > Conversation.
2. Set Speech to Text to Native iOS Live.
3. Enable Continue Voice Chat When Locked and confirm the disclosure.
4. Return to a chat and start a voice conversation with the microphone button.

With Speech to Text set to Native iOS Live, PocketMai uses Apple's on-device
SpeechTranscriber API. Raw microphone audio is not uploaded by PocketMai.
Audio recordings for spoken turns are saved locally on the device as part of
the conversation history. After transcription, the resulting text is sent only
when the user submits a voice turn to their selected chat provider.

The locked-screen setting is off by default. It is available only for Native iOS
Live and applies only while an active voice conversation is running. Voice
capture stops when the user ends the voice conversation, disables the setting,
or switches Speech to Text to Native iOS File.

Privacy labels should disclose speech/audio data according to the configured
providers and whether the user stores voice recordings in conversation history.

## Background replies

Settings > Look and Feel > Background & Notifications controls three optional
behaviours, none of which run without a user-started reply:

- **Live Activity** (on by default): while a reply or tool call runs, a Live
  Activity shows its progress on the Lock Screen and in the Dynamic Island. It
  ends when the reply finishes and is removed a few minutes later, or as soon
  as the app is reopened.
- **Notifications** (on by default, subject to the system permission prompt):
  a local notification is posted when a reply finishes, fails, or waits for a
  tool-call approval while PocketMai is in the background or the device is
  locked. Nothing is posted while the app is on screen. No push notifications
  or servers are involved.
- **Keep working when locked** (off by default): renders silence through the
  existing `audio` background mode so an in-flight reply is not suspended when
  the screen locks. It starts only while a reply is running and the app is in
  the background, and stops as soon as the reply ends or the app returns to
  the foreground. The user is told it uses more battery.
