# Turtle WoW disenchant data provenance

Generated lookup source:
- repository: `tortoise-wow/tortoise-wow`
- exact commit: `d94947b0db60c33e7248523ad0ba7f58af97fd09`
- `sql/base/tw_world_item_template.sql`
- `sql/base/tw_world_disenchant_loot_template.sql`
- later world updates applied in order:
  - `sql/database_updates/world/20260629195406_world.sql`
  - `sql/database_updates/world/20260714180156_world.sql`
  - `sql/database_updates/world/20260816173710_world.sql`

Generated coverage:
- positive item -> disenchant ID mappings: 9131
- known quality 2/3/4 equip items blocked because server `disenchant_id=0`: 1672
- disenchant loot IDs: 36
- final source item rows after updates: 23635

Runtime policy: exact Turtle data for known items, fail-closed for known non-disenchantable equip items, and original AUX distribution only for item IDs absent from this pinned snapshot. Existing AH material-depth valuation and buy safety gates are unchanged.

The source repository declares GNU Affero General Public License v3.0. Its exact upstream `LICENSE` at the pinned commit is authoritative. This generated file copies only database facts required for the client lookup and records exact transformation provenance.

Generation sentinel: Alabaster Shield (item 8320) -> disenchant ID 30.
