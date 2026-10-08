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

SUFFIX=(
    '\ninclude!("../../../src/AuctionLifecycle/adapter.rs");\n'
    'include!("../../../src/AuctionLifecycle/market_maker_inventory.rs");\n'
    'include!("../../../src/AuctionLifecycle/market_maker.rs");\n'
)

class Integration(unittest.TestCase):
    def test_actual_canonical_anchors_and_buy_body_preserved(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td)
            shutil.copytree(ROOT/SRC,root/SRC)
            before=(root/SRC/'world_poc07.rs').read_text()
            m.integrate(root)
            after=(root/SRC/'world_poc07.rs').read_text()
            self.assertEqual(after.replace('fn poc07_buy_exact_one_canonical(', 'fn poc07_buy_exact_one(').removesuffix(SUFFIX),before)
            main=(root/SRC/'main.rs').read_text()
            self.assertIn('mod market_maker_policy;',main)
            files={p:p.read_bytes() for p in (root/SRC).glob('*.rs')}
            with self.assertRaises(ValueError):m.integrate(root)
            self.assertEqual(files,{p:p.read_bytes() for p in (root/SRC).glob('*.rs')})
    def test_buy_safety_and_market_maker_contract(self):
        main=(ROOT/SRC/'main.rs').read_text()
        self.assertIn('error.contains("MAIL_MUTATION_") || error.contains("AH_MUTATION_")',main)
        core=Path(__file__).with_name('coordinator.rs').read_text()
        self.assertIn('AH_MUTATION_COORDINATOR_HARD_STOP',core)
        self.assertIn('create_new(true)',core)
        self.assertIn('p.sync_all()',core)
        self.assertIn('Split',core)
        self.assertIn('0x10e',core)
        mm=Path(__file__).with_name('market_maker.rs').read_text()
        self.assertIn('poc07_buy_exact_one(',mm)
        self.assertIn('lifecycle_cancel(',mm)
        self.assertIn('mm_split_all_to_units(',mm)
        self.assertIn('lifecycle_post(',mm)
        self.assertIn('c.max_clear_units>c.max_post_units',mm)
        self.assertIn('MARKET_MAKER final pricing snapshot incomplete; stock held, not posted',mm)
        self.assertIn('WOW112_MM_MIN_PRICE_BPS_OF_OWN",0',mm)
        self.assertIn('clear-local-a',mm)
        self.assertIn('clear-local-b',mm)
        self.assertIn('WOW112_MM_ACTION_FILTER',mm)
        self.assertIn('action_filter!=1',mm)
        self.assertIn('action_filter!=2',mm)
        self.assertIn('item-local depth changed between confirmation scans',mm)
        self.assertNotIn('s.complete&&s.stable',mm)
        inv=Path(__file__).with_name('market_maker_inventory.rs').read_text()
        self.assertIn('CMSG_SPLIT_ITEM',inv)
        self.assertIn('mutations::transaction(MutationKind::Split',inv)
        self.assertNotIn('MM_SPLIT_INTENT',inv)
        adapter=Path(__file__).with_name('adapter.rs').read_text()
        self.assertNotIn('inventory_bad',adapter)
        self.assertIn('object update parse skipped',adapter)
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
            self.assertEqual(after.replace('fn poc07_buy_exact_one_canonical(', 'fn poc07_buy_exact_one(').removesuffix(SUFFIX),buy)
            self.assertIn('POC08-UNIFIED-V4',unified)
            self.assertIn('return lifecycle_dispatch', (root/SRC/'world_poc08_unified.rs').read_text())
if __name__=='__main__':unittest.main()
