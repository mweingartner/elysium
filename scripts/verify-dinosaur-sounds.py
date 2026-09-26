#!/usr/bin/env python3
"""Fail closed on an incomplete, altered or unsafe bundled dinosaur sound bank."""
import argparse
import array
import hashlib
import json
from pathlib import Path
import re
import sys
import wave

ROOT = Path(__file__).resolve().parents[1]

def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify(directory):
    canonical = ROOT / 'packaging/DinosaurSounds/manifest.json'
    manifest_path = directory / 'manifest.json'
    require(not directory.is_symlink() and not manifest_path.is_symlink(), 'symlink bank')
    require(manifest_path.read_bytes() == canonical.read_bytes(), 'manifest differs from reviewed source')
    manifest = json.loads(canonical.read_text())
    roster = re.findall(r'definition\("([a-z]+)",',
                        (ROOT / 'Sources/ElysiumCore/Entity/PrehistoricCreatures.swift').read_text())
    expected = {f'{species}-{action}.wav' for species in roster for action in ('grazing','attack','injured')}
    records = manifest['assets']
    require(len(roster) == 36 and len(records) == 108, 'invalid dinosaur bank contract')
    require({r['file'] for r in records} == expected, 'invalid dinosaur bank contract')
    require({p.name for p in directory.iterdir()} == expected | {'manifest.json'}, 'unexpected or missing asset')
    hashes = set()
    for record in records:
        path = directory / record['file']
        require(not path.is_symlink() and path.is_file(), f'nonregular file: {path.name}')
        require(44 < path.stat().st_size <= 512000, 'invalid dinosaur bank contract')
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        require(digest == record['sha256'], f'hash mismatch: {path.name}')
        require(digest not in hashes, f'duplicate recording: {path.name}')
        hashes.add(digest)
        with wave.open(str(path)) as audio:
            require((audio.getnchannels(), audio.getsampwidth(), audio.getframerate(), audio.getcomptype()) == (1,2,24000,'NONE'), 'invalid dinosaur bank contract')
            require(12000 <= audio.getnframes() <= 192000, 'invalid dinosaur bank contract')
            require(audio.getnframes() == record['frames'], 'invalid dinosaur bank contract')
            samples = array.array('h', audio.readframes(audio.getnframes()))
            if sys.byteorder != 'little': samples.byteswap()
            require(100 < max(map(abs,samples)) <= 17000, f'peak outside headroom: {path.name}')
            require(abs(samples[0]) <= 1 and abs(samples[-1]) <= 1, f'unclean endpoints: {path.name}')
    print('Dinosaur sounds PASS species=36 actions=3 unique=108 PCM=mono/24000/16 range=40')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, default=ROOT/'packaging/DinosaurSounds')
    args = parser.parse_args()
    try: verify(args.directory)
    except (OSError, ValueError, KeyError, TypeError, wave.Error) as error:
        print(f'Dinosaur sounds FAIL: {error}', file=sys.stderr)
        sys.exit(1)
