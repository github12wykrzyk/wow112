import importlib.util
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
SRC=Path('probes/Wow112HeadlessAndroid/src')
spec=importlib.util.spec_from_file_location('integration',Path(__file__).with_name('integrate.py'))
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

class Integration(unittest.TestCase):
    def test_actual_canonical_anchors_and_buy_body_preserved(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td)
            shutil.copytree(ROOT/SRC,root/SRC)
            before=(root/SRC/'world_poc07.rs').read_text()
            m.integrate(root)
            after=(root/SRC/'world_poc07.rs').read_text()
            self.assertEqual(after.replace('fn poc07_buy_exact_one_canonical(', 'fn poc07_buy_exact_one(').removesuffix('\ninclude!("../../../src/AuctionLifecycle/adapter.rs");\n'),before)
            files={p:p.read_bytes() for p in (root/SRC).glob('*.rs')}
            with self.assertRaises(ValueError):m.integrate(root)
            self.assertEqual(files,{p:p.read_bytes() for p in (root/SRC).glob('*.rs')})
    def test_buy_safety_and_reconnect_contract_unchanged(self):
        main=(ROOT/SRC/'main.rs').read_text()
        self.assertIn('error.contains("MAIL_MUTATION_") || error.contains("AH_MUTATION_")',main)
        core=Path(__file__).with_name('coordinator.rs').read_text()
        self.assertIn('AH_MUTATION_COORDINATOR_HARD_STOP',core)
        self.assertIn('create_new(true)',core)
        self.assertIn('p.sync_all()',core)
    def test_all_v4_generation_then_integration(self):
        import yaml
        with tempfile.TemporaryDirectory() as td:
            root=Path(td)
            shutil.copytree(ROOT/'probes',root/'probes')
            wf=yaml.safe_load((ROOT/'.github/workflows/build_windows_ah_de_liquidation_v3.yml').read_text())
            for step in wf['jobs']['build']['steps']:
                for line in step.get('run','').splitlines():
                    if not line.strip().startswith('python probes/'):continue
                    if 'build_de_cache' in line or 'poc08_de_cache_to_rust_provenance' in line:continue
                    args=line.strip().split()
                    subprocess.run([sys.executable,*args[1:]],cwd=root,check=True,stdout=subprocess.DEVNULL)
            buy=(root/SRC/'world_poc07.rs').read_text()
            unified=(root/SRC/'world_poc08_unified.rs').read_text()
            m.integrate(root)
            after=(root/SRC/'world_poc07.rs').read_text()
            self.assertEqual(after.replace('fn poc07_buy_exact_one_canonical(', 'fn poc07_buy_exact_one(').removesuffix('\ninclude!("../../../src/AuctionLifecycle/adapter.rs");\n'),buy)
            self.assertIn('POC08-UNIFIED-V4',unified)
            self.assertIn('return lifecycle_run', (root/SRC/'world_poc08_unified.rs').read_text())
if __name__=='__main__':unittest.main()
