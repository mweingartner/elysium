#!/usr/bin/env python3
"""Author the committed dinosaur bank from official Suno masters (requires ffmpeg).
No network or generation requests. Runtime and packaging never invoke this tool.
"""
import array
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import wave

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / 'Assets/dinosaur-audio'
OUTPUT = ROOT / 'packaging/DinosaurSounds'
ACTIONS = ('grazing', 'attack', 'injured')


def pcm(path):
    with wave.open(str(path)) as w:
        assert w.getsampwidth() == 2
        data = array.array('h', w.readframes(w.getnframes()))
        if sys.byteorder != 'little':
            data.byteswap()
        return data, w.getframerate(), w.getnchannels()


def main():
    source_manifest = json.loads((ASSETS / 'sources.json').read_text())
    sources = {s['key']: s for s in source_manifest['sources']}
    roster = re.findall(r'definition\("([a-z]+)", "[^"]+", \.(\w+), \.(\w+), ([\d.]+)',
                        (ROOT / 'Sources/ElysiumCore/Entity/PrehistoricCreatures.swift').read_text())
    assert len(roster) == 36
    records = []
    OUTPUT.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='elysium-audio-') as tmp:
        for index, (species, medium, family, length) in enumerate(roster):
            voice = ('marine' if medium == 'aquatic' else 'pterosaur' if medium == 'air' else
                     'raptor' if family == 'smallTheropod' else
                     'tyrannosaurus' if family == 'largeTheropod' else
                     'triceratops' if family in ('ceratopsian', 'armoredHerbivore', 'sauropod') else 'hadrosaur')
            reference_length = {'marine': 6, 'pterosaur': 4, 'raptor': 3, 'tyrannosaurus': 12,
                                'triceratops': 8, 'hadrosaur': 9}[voice]
            # Size gives a broad voice register; the stable roster signature separates peers.
            pitch = round(max(.65, min(1.5, (reference_length / float(length)) ** .20)) *
                          (1 + (index % 7 - 3) * .018), 5)
            tempo = round(.94 + index * .004, 4)
            resonance = 380 + index * 73
            for action in ACTIONS:
                key = voice + '-' + action
                source = sources[key]
                original = ASSETS / source['original']
                assert hashlib.sha256(original.read_bytes()).hexdigest() == source['sha256']
                # Select the first phrase using 20 ms energy windows, preserving a natural tail.
                raw, rate, channels = pcm(original)
                mono = [sum(raw[i:i+channels]) / channels for i in range(0, len(raw), channels)]
                window = rate // 50
                levels = [max(map(abs, mono[i:i+window]), default=0) for i in range(0, len(mono), window)]
                threshold = max(100, max(levels) * .022)
                onset = next(i for i, level in enumerate(levels) if level > threshold)
                start = max(0, onset * .02 - .025)
                end = min(len(mono) / rate, start + (3.0 if action == 'grazing' else 2.4))
                quiet = 0
                for i in range(onset + 15, min(len(levels), int(end * 50))):
                    quiet = quiet + 1 if levels[i] < threshold else 0
                    if quiet >= 12:
                        end = max(start + .65, (i - quiet + 1) * .02 + .12)
                        break
                filters = (f'atrim=start={start:.4f}:end={end:.4f},asetpts=PTS-STARTPTS,'
                           f'aresample=24000,asetrate={round(24000*pitch)},aresample=24000,'
                           f'atempo={tempo},highpass=f=45,equalizer=f={resonance}:t=q:w=1:g=3')
                intermediate = Path(tmp) / 'edit.wav'
                subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', str(original), '-ac', '1',
                                '-af', filters, '-ar', '24000', '-c:a', 'pcm_s16le', str(intermediate)], check=True)
                data, rate, _ = pcm(intermediate)
                # Peak normalization with quieter feeding and ample mixer headroom.
                target = .28 if action == 'grazing' else .50 if action == 'attack' else .42
                gain = target * 32767 / max(map(abs, data))
                fade_in, fade_out = 120, 1440
                for i, value in enumerate(data):
                    envelope = min(1, i / fade_in, (len(data) - 1 - i) / fade_out)
                    data[i] = round(value * gain * max(0, envelope))
                name = species + '-' + action + '.wav'
                if sys.byteorder != 'little':
                    data.byteswap()
                with wave.open(str(OUTPUT / name), 'wb') as w:
                    w.setparams((1, 2, 24000, 0, 'NONE', 'not compressed'))
                    w.writeframes(data.tobytes())
                records.append(dict(file=name, source=key, source_url=source['url'],
                                    trim_start=round(start,4), trim_end=round(end,4), pitch=pitch,
                                    tempo=tempo, resonance_hz=resonance, peak_target=target,
                                    fade_in_seconds=.005, fade_out_seconds=.06,
                                    frames=len(data), sha256=hashlib.sha256((OUTPUT/name).read_bytes()).hexdigest()))
    manifest = dict(schema=1, sample_rate=24000, channels=1, bits_per_sample=16,
                    max_distance_blocks=40, source_manifest='Assets/dinosaur-audio/sources.json',
                    audible_acceptance='See hash-bound user acceptance; assistant did not audition', assets=records,
                    user_accepted_assets=[r['file'] for r in records
                        if source_manifest['review'].get('user_acceptance', {}).get(
                            'runtime_sha256s', {}).get(r['file']) == r['sha256']])
    (OUTPUT / 'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
    print(f'Authored {len(records)} species/action WAVs from {len(sources)} official masters')

if __name__ == '__main__':
    main()
