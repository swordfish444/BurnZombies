# Narration

## Script

| Cue | Line |
| --- | --- |
| 0.40 s | Your AI agents never sleep. |
| 3.10 s | But they leave a mess. |
| 4.65 s | Zombie processes. |
| 6.40 s | Stale worktrees. |
| 7.80 s | Gigabytes of build junk. |
| 10.70 s | BurnZombies burns it all, on its own. |
| 13.85 s | Every worktree is backed up first. |
| 16.35 s | Six hundred and eighty-five gigabytes, freed in two days. |
| 20.60 s | You build. |
| 21.60 s | We burn. |

The lines and their cues are in `lines/durations.json`, and their word times, which drive the captions, are in `lines/words.json`.

## Voice

Google's Gemini 3.8 Flash TTS, voice **Umbriel**, through OpenRouter's `/api/v1/audio/speech` (`speak.py`). Style direction:

> Warm, confident premium commercial voiceover for a developer tool. A seasoned engineer talking to another engineer: grounded mid-low register, a slight knowing smile, clear and natural, never hype. Keep it moving: about 2.7 words per second, with short, clean pauses of about half a second between sentences and a brief beat between 'Zombie processes.', 'Stale worktrees.' and 'Gigabytes of build junk.' Say 'worktree' and 'worktrees' as one word with the stress on 'work', like 'workflow'. Say 'BurnZombies' as one brand name, stress on 'Zom'. End 'You build.' and 'We burn.' with a falling, final intonation: quiet confidence, not a question.

What is used: take 3 of three full-script takes for seven lines, and pickups (`pickups.py`, a direction for a falling, final read) for "Gigabytes of build junk.", "You build." and "We burn.", whose ends rose like questions in every full take. The pickups were tone-matched to the take (at most ±3 dB, one-octave smoothing). The first five lines play 7% faster than read, pitch preserved; "on its own" has a 150 ms breath before it.

## How the voice was chosen

On November 5, 2026, sixteen full-script takes went through the same script and direction (`bakeoff.py`): Gemini 3.8 Flash TTS (Algieba, Charon, Orus, Achird, Umbriel), Microsoft MAI-Voice-2.1 (Grant, Jasper, Ethan), ElevenLabs Eleven v4 (Brian, Adam, George, Roger) and MiniMax Speech 2.8 HD (four narrator voices). Each take was scored by a whisper transcript against the script, by UTMOS, and blind by listening models on OpenRouter (`judge.py`).

- Gemini Pro scored Gemini Umbriel and Algieba 9 of 10, and every other take 7 or lower.
- Qwen omni rated Umbriel highest (6; it scores everything low).
- GPT Audio refused to rate half the takes; of those it rated, it gave Algieba and ElevenLabs George 8.
- OpenRouter's own arena ranks Gemini 3.8 Flash TTS first for text-to-speech.

Casey's GradeGate films use the same model's **Knox** voice from Google AI Studio. Knox is not offered through the API, so Umbriel won the blind comparison instead.

The final soundtrack was judged the same way: Gemini Pro scored it 8 of 10 for voice quality, clarity over the mix, music fit, sound design, excitement and premium feel.

## Replacing a line

Generate takes with `speak.py` or `pickups.py` (an OpenRouter key in `OPENROUTER_API_KEY`), cut a full take into lines with `cut.py`, copy the lines into `lines/`, and update `durations.json` and `words.json`. Every line must end before the next cue, and the whisper transcript of the final mix must match the script.
