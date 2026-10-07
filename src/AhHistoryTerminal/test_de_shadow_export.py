#!/usr/bin/env python3
import csv
import pathlib
import tempfile
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import export_de_shadow_csv as exporter
from test_history_quality_v2 import make_db


def test_de_material_filter_and_provenance():
    db = make_db()
    with tempfile.TemporaryDirectory() as td:
        db_path = pathlib.Path(td) / 'history.sqlite'
        disk = __import__('sqlite3').connect(db_path)
        db.backup(disk)
        disk.close()
        db.close()
        output = pathlib.Path(td) / 'shadow.csv'
        result = exporter.export_shadow(str(db_path), 'm', str(output), 3000)
        assert result['exported_materials'] == 1, result
        with output.open(newline='', encoding='utf-8') as handle:
            rows = list(csv.DictReader(handle))
        assert len(rows) == 1
        assert rows[0]['item_id'] == '10940'
        assert int(rows[0]['unit_copper']) > 0
        assert rows[0]['view_id'] == result['view_id']
        assert rows[0]['ruleset'] == 'ah-quality-v2.0'


if __name__ == '__main__':
    test_de_material_filter_and_provenance()
    print('PASS test_de_material_filter_and_provenance')
