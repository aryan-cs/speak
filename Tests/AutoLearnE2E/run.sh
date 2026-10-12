#!/bin/zsh
# Builds the capture probe from Speak's current Auto Learn sources, opens the chat box in a fresh
# Chrome (new profile, so nothing has switched its accessibility on), and runs the scenarios.
set -e
HERE=${0:A:h}
REPO=${HERE:h:h}
AL=$REPO/VoiceInk/Features/Dictionary/AutoLearn
WORK=${TMPDIR%/}/speak-autolearn-e2e
mkdir -p $WORK
xcrun --sdk macosx swiftc -O -o $WORK/probe $HERE/main.swift $HERE/Stubs.swift \
  $AL/AutoLearnAXRuntime.swift $AL/AutoLearnAXTextReader.swift $AL/AutoLearnTypes.swift \
  $AL/FinalSnapshotDiffEngine.swift $AL/CorrectionDiffEngine.swift \
  $REPO/VoiceInk/Features/Dictionary/Workflows/WordReplacementVariants.swift

pkill -f "remote-debugging-port=9444" 2>/dev/null || true
rm -rf $WORK/chrome-profile
open -na "Google Chrome" --args --user-data-dir=$WORK/chrome-profile --no-first-run --no-default-browser-check \
  --remote-debugging-port=9444 --window-position=160,90 --window-size=900,760 --app=file://$HERE/composer.html
for i in {1..40}; do curl -s http://127.0.0.1:9444/json 2>/dev/null | grep -q composer.html && break; sleep 0.5; done
sleep 3

print -r -- "Add the setup with the grok key and the olama model to the README. " > $WORK/one-paragraph.txt
print -r -- "I don't think it's still looking for it when I use it. For example, when I say the word “whisper flow,” it gets spelled wrong.

But when I changed the text, it didn't show me a message saying it was updating. " > $WORK/two-paragraphs.txt

fresh_chrome() {
  pkill -f "remote-debugging-port=9444" 2>/dev/null || true
  sleep 1; rm -rf $WORK/chrome-profile
  open -na "Google Chrome" --args --user-data-dir=$WORK/chrome-profile --no-first-run --no-default-browser-check \
    --remote-debugging-port=9444 --window-position=160,90 --window-size=900,760 --app=file://$HERE/composer.html
  for i in {1..40}; do curl -s http://127.0.0.1:9444/json 2>/dev/null | grep -q composer.html && break; sleep 0.5; done
  sleep 3
}

# Each scenario starts from a Chrome nobody has touched, as in real use.
for scenario in "one-paragraph.txt|olama=>Ollama|" "one-paragraph.txt|olama=>Ollama|--dictation-start" "two-paragraphs.txt|whisper flow=>Wispr Flow|--dictation-start"; do
  parts=("${(@s:|:)scenario}")
  fresh_chrome
  echo "=== ${parts[1]} (fix ${parts[2]}, then Return) ${parts[3]}"
  $WORK/probe $WORK/${parts[1]} --fix "${parts[2]}" --send --select-in-page --edit-in-page ${parts[3]}
done
pkill -f "remote-debugging-port=9444" 2>/dev/null || true
