# Third-party Turtle WoW vendor value data

`AuxVmangos_VendorData.lua` contains the **Turtle WoW Item Vendor Prices** table copied from:

- Repository: `shagu/ShaguTweaks`
- File: `mods/turtle-wow.lua`
- Exact commit: `7d670218a9b1e0a6a9a9062c0f458508398f2e48`
- Commit message: `turtle-wow: update sell value database to 1.18`
- Upstream table name: `selldata`
- Entries copied: 17703 total (17316 positive sell values)

The project stores the table as `AVM_VENDOR_VALUES` in copper per item. Runtime priority is:

1. realm-observed `aux.account_data.merchant_sell[itemId]` when AUX has learned an actual sell value;
2. this Turtle WoW-specific database;
3. no vendor valuation.

There is deliberately **no fallback to the previous generic Vanilla vendor table**. Report #71 on exact project SHA `a6a593b62e7e7fb2e7ee5dbbc51e9acc27c4098a` showed why this matters: the old table had Serrated Petal (item 18223) at 6142 copper, while this Turtle 1.18 table has 1228 copper. The Turtle-specific source also contains item 10406 at 1976 copper, item 7972 at 400 copper and item 8152 at 500 copper.

## License

ShaguTweaks is distributed under the MIT License:

MIT License

Copyright (c) 2021 Eric Mauser (Shagu)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE.
