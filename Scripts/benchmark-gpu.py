#!/usr/bin/env python3
"""Run repeatable 3DMark measurements on an already booted isolated benchmark AVD.

Start a backend as documented in docs/GPU-BENCHMARKS.md, install the official
3DMark APK and test assets, and open its English benchmark selection screen.
This tool preserves raw results, screenshots and thermal status. It never
changes the benchmark workload or synthesizes scores.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import time
import xml.etree.ElementTree as ET


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--adb', type=Path, required=True)
    parser.add_argument('--adb-port', type=int, default=5141)
    parser.add_argument('--serial', default='emulator-5570')
    parser.add_argument('--avd', default='gpu-benchmark')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--profile', required=True, help='Label for the actual launch configuration')
    parser.add_argument('--test', choices=['WILD LIFE', 'SLING SHOT'], default='WILD LIFE')
    parser.add_argument('--runs', type=int, default=3)
    parser.add_argument('--unlimited', action='store_true', help='Use the Unlimited variant (portrait selection UI required)')
    parser.add_argument('--timeout', type=int, default=600)
    args = parser.parse_args()
    if args.runs < 1 or args.timeout < 60:
        parser.error('Runs must be positive and timeout must be at least 60 seconds')
    if not re.fullmatch(r'[A-Za-z0-9_-]+', args.profile):
        parser.error('Profile labels may contain only letters, digits, underscores and hyphens')
    out = args.output.expanduser().resolve()
    out.mkdir(parents=True, exist_ok=True)
    adb = [str(args.adb.expanduser().resolve()), '-P', str(args.adb_port), '-s', args.serial]

    def shell(*words):
        return subprocess.check_output(adb + ['shell', *words], text=True, timeout=30)

    if shell('getprop', 'ro.boot.qemu.avd_name').strip() != args.avd:
        parser.error('Connected device does not match the expected benchmark AVD')

    def nodes():
        shell('uiautomator', 'dump', '/sdcard/mandroid-benchmark.xml')
        xml = shell('cat', '/sdcard/mandroid-benchmark.xml')
        return xml, list(ET.fromstring(xml).iter('node'))

    def tap(node):
        x1, y1, x2, y2 = map(int, re.findall(r'\d+', node.get('bounds')))
        shell('input', 'tap', str((x1 + x2) // 2), str((y1 + y2) // 2))

    metadata = {
        'profile': args.profile,
        'test': args.test + (' UNLIMITED' if args.unlimited else ''),
        'guestFingerprint': shell('getprop', 'ro.build.fingerprint').strip(),
        'gles': [line.strip() for line in shell('dumpsys', 'SurfaceFlinger').splitlines() if 'GLES:' in line],
        '3dmarkVersion': [line.strip() for line in shell('dumpsys', 'package', 'com.futuremark.dmandroid.application').splitlines()
                          if 'versionName=' in line or 'versionCode=' in line],
    }
    stamp = time.strftime('%Y%m%d-%H%M%S')
    (out / f'{args.profile}-{stamp}-device.json').write_text(json.dumps(metadata, indent=2))
    for number in range(1, args.runs + 1):
        _, tree = nodes()
        if any(node.get('text') == 'Overall score' for node in tree):
            shell('input', 'keyevent', '4')
            time.sleep(2)
            _, tree = nodes()
        if args.unlimited:
            shell('wm', 'user-rotation', 'lock', '1')
            time.sleep(1)
            _, tree = nodes()
        tab = next((node for node in tree if node.get('text') == args.test), None)
        for _ in range(4):
            if tab is not None:
                break
            bar = next((node for node in tree if node.get('resource-id', '').endswith('/flm_tab_layout_benchmarks')), None)
            if bar is None:
                break
            x1, y1, x2, y2 = map(int, re.findall(r'\d+', bar.get('bounds')))
            start_x, end_x = x1 + (x2 - x1) // 5, x1 + 4 * (x2 - x1) // 5
            # Wild Life is near the start of the tab strip; Sling Shot is later.
            if args.test == 'SLING SHOT':
                start_x, end_x = end_x, start_x
            shell('input', 'swipe', str(start_x), str((y1 + y2) // 2),
                  str(end_x), str((y1 + y2) // 2), '400')
            _, tree = nodes()
            tab = next((node for node in tree if node.get('text') == args.test), None)
        if tab is None:
            raise RuntimeError('Open the benchmark selection screen with the requested test tab visible')
        tap(tab)
        time.sleep(1)
        _, tree = nodes()
        if any('progress_perc' in node.get('resource-id', '') for node in tree):
            raise RuntimeError('Finish downloading the test assets before measuring')
        button = next((node for node in tree if node.get('resource-id', '').endswith('/flm_fab_benchmark')), None)
        if button is None:
            raise RuntimeError('Benchmark is not ready to run')
        label = f'{args.profile}-{metadata["test"].lower().replace(" ", "-")}-{stamp}-{number}'
        (out / f'{label}-thermal.txt').write_text(subprocess.check_output(['pmset', '-g', 'therm'], text=True))
        if args.unlimited:
            gear = next((node for node in tree if node.get('resource-id', '').endswith('/flm_fab_settings')), None)
            if gear is None:
                raise RuntimeError('Unlimited selector is hidden; rotate the selection UI to portrait without changing benchmark resolution')
            tap(gear)
            time.sleep(1)
            _, tree = nodes()
            choice = next(node for node in tree if node.get('text') == args.test.title() + ' Unlimited')
            tap(choice)
            _, tree = nodes()
            button = next(node for node in tree if node.get('text') == 'RUN')
        app_pid = shell('pidof', 'com.futuremark.dmandroid.application').strip()
        print(f'START {label}', flush=True)
        tap(button)
        start = time.monotonic()
        time.sleep(45)
        while time.monotonic() - start < args.timeout:
            current_pid = subprocess.run(adb + ['shell', 'pidof', 'com.futuremark.dmandroid.application'],
                                         capture_output=True, text=True, timeout=30).stdout.strip()
            if current_pid != app_pid:
                failure = dict(metadata, error='3DMark process exited or restarted during measurement',
                               originalPID=app_pid, currentPID=current_pid)
                (out / f'{label}-failed.json').write_text(json.dumps(failure, indent=2))
                (out / f'{label}-crash.txt').write_text(shell('logcat', '-b', 'crash', '-d'))
                raise RuntimeError(failure['error'])
            activities = shell('dumpsys', 'activity', 'activities')
            top = next((line.strip() for line in activities.splitlines() if 'topResumedActivity=' in line), '')
            if 'BenchmarkResult' in top:
                time.sleep(2)
                xml, tree = nodes()
                texts = [node.get('text') for node in tree if node.get('text')]
                result = dict(metadata, elapsedSeconds=round(time.monotonic() - start, 1), texts=texts)
                if 'Overall score' in texts:
                    value = texts[texts.index('Overall score') + 1]
                    if re.fullmatch(r'[\d\s,]+', value):
                        result['score'] = int(re.sub(r'\D', '', value))
                (out / f'{label}.xml').write_text(xml)
                (out / f'{label}.json').write_text(json.dumps(result, indent=2))
                with (out / f'{label}.png').open('wb') as image:
                    subprocess.run(adb + ['exec-out', 'screencap', '-p'], stdout=image, check=True)
                print(json.dumps(result), flush=True)
                if 'score' not in result:
                    raise RuntimeError('Result has no numeric score; inspect saved evidence (a maxed-out test is not a numeric result)')
                break
            if '/.MainActivity ' in top:
                xml, tree = nodes()
                texts = [node.get('text') for node in tree if node.get('text')]
                if 'Benchmark failed to run' in texts:
                    (out / f'{label}-failed.xml').write_text(xml)
                    (out / f'{label}-failed.json').write_text(json.dumps(dict(metadata, error=texts), indent=2))
                    with (out / f'{label}-failed.png').open('wb') as image:
                        subprocess.run(adb + ['exec-out', 'screencap', '-p'], stdout=image, check=True)
                    raise RuntimeError(f'Benchmark failed before producing a score: {texts}')
            print(f'RUNNING {label}: {int(time.monotonic() - start)}s {top}', flush=True)
            time.sleep(10)
        else:
            raise RuntimeError('Result observation timed out; inspect the existing benchmark before restarting')
        if number < args.runs:
            shell('input', 'keyevent', '4')
            time.sleep(20)


if __name__ == '__main__':
    main()
