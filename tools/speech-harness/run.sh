#!/bin/sh
# 声の区切り（SpeechWordRecognizer）を Mac で試す。詳しくは main.swift の先頭を参照。
# 使い方: tools/speech-harness/run.sh [単語間の無音ms=400] [雑音dBFS=-60 か off] [単語...]
set -e
cd "$(dirname "$0")/../.."
mkdir -p build/speech-harness
swiftc -O -swift-version 5 -default-isolation MainActor \
    -enable-upcoming-feature MemberImportVisibility \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -enable-upcoming-feature InferIsolatedConformances \
    -enable-upcoming-feature InferSendableFromCaptures \
    -enable-upcoming-feature GlobalActorIsolatedTypesUsability \
    -enable-upcoming-feature DisableOutwardActorInference \
    OdaiAttack/Speech/SpeechTuning.swift \
    OdaiAttack/Speech/VoiceActivityDetector.swift \
    OdaiAttack/Speech/SpokenWords.swift \
    OdaiAttack/Speech/SpeechWordRecognizer.swift \
    OdaiAttack/Formatting.swift \
    tools/speech-harness/main.swift \
    -o build/speech-harness/run
exec build/speech-harness/run "$@"
