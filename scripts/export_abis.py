#!/usr/bin/env python3
"""Export compiler-generated ABIs, or compare the delivered exports to the current build."""
import argparse
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--check', action='store_true', help='fail if an exported ABI differs')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
for name in ('GASP', 'GasPriceFeeHook'):
    result = subprocess.run(
        ['forge', 'inspect', f'src/{name}.sol:{name}', 'abi', '--json'],
        cwd=root, check=True, capture_output=True, text=True,
    )
    abi = json.loads(result.stdout)
    target = root / 'docs' / 'abi' / f'{name}.json'
    if args.check:
        if not target.exists() or json.loads(target.read_text()) != abi:
            raise SystemExit(f'ABI differs: {target.relative_to(root)}')
        print(f'ABI verified: {target.relative_to(root)}')
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(abi, indent=2) + '\n')
        print(f'ABI exported: {target.relative_to(root)}')
