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
