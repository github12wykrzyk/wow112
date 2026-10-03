local R = W112_AH_SHADOW
if type(R) ~= "table" or type(R.ReplaceModule) ~= "function" then
    error("AuxEconomyShadow market book requires persistent anchor")
end

local REVISION = "2-listings-market-book"
local ok = R.ReplaceModule("marketbook", REVISION, function(state)
    state.books = type(state.books) == "table" and state.books or {}
    state.nextGeneration = tonumber(state.nextGeneration) or 0
    local api = {}
    api.revision = REVISION

    local function resolve(bookOrName)
        if type(bookOrName) == "table" then return bookOrName end
        return state.books[tostring(bookOrName or "default")]
    end

    function api.New(name)
        name = tostring(name or "default")
        state.nextGeneration = state.nextGeneration + 1
        local book = {
            name = name,
            generation = state.nextGeneration,
            records = {},
            byItem = {},
            pages = {},
            count = 0,
            buyoutCount = 0,
            bidOnlyCount = 0,
            totalUnits = 0,
        }
        state.books[name] = book
        return book
    end

    function api.Get(name)
        return state.books[tostring(name or "default")]
    end

    function api.Reset(name)
        name = tostring(name or "default")
        state.books[name] = nil
        return true
    end

    function api.Add(bookOrName, raw)
        local book = resolve(bookOrName)
        if not book then return nil, "book-unavailable" end
        local contracts = R.GetModule("contracts")
        if not contracts then return nil, "contracts-unavailable" end
        local record, reason = contracts.NormalizeListing(raw)
        if not record then return nil, reason end
        if not record.signature or record.signature == "" then
            record.signature = contracts.Signature(record, true)
        end

        table.insert(book.records, record)
        book.count = book.count + 1
        book.totalUnits = book.totalUnits + record.count
        book.pages[record.sourcePage] = (tonumber(book.pages[record.sourcePage]) or 0) + 1
        if record.buyout > 0 then book.buyoutCount = book.buyoutCount + 1
        else book.bidOnlyCount = book.bidOnlyCount + 1 end

        local row = book.byItem[record.itemId]
        if not row then
            row = { itemId = record.itemId, listings = {}, offers = {}, units = 0, sorted = true }
            book.byItem[record.itemId] = row
        end
        table.insert(row.listings, record)
        if record.buyout > 0 then
            table.insert(row.offers, record)
            row.units = row.units + record.count
            row.sorted = false
        end
        return record, nil
    end

    function api.ItemOffers(bookOrName, itemId)
        local book = resolve(bookOrName)
        if not book then return nil end
        local row = book.byItem[tonumber(itemId)]
        if not row then return nil end
        if not row.sorted then
            table.sort(row.offers, function(a, b)
                if a.unit ~= b.unit then return a.unit < b.unit end
                if a.buyout ~= b.buyout then return a.buyout < b.buyout end
                return a.count > b.count
            end)
            row.sorted = true
        end
        return row.offers, row.units
    end

    function api.ItemListings(bookOrName, itemId)
        local book = resolve(bookOrName)
        if not book then return nil end
        local row = book.byItem[tonumber(itemId)]
        return row and row.listings or nil
    end

    function api.Records(bookOrName)
        local book = resolve(bookOrName)
        return book and book.records or nil
    end

    function api.Snapshot(bookOrName)
        local book = resolve(bookOrName)
        if not book then return nil end
        local itemKinds = 0
        for _ in pairs(book.byItem) do itemKinds = itemKinds + 1 end
        local pageKinds = 0
        for _ in pairs(book.pages) do pageKinds = pageKinds + 1 end
        return {
            name = book.name,
            generation = book.generation,
            count = book.count,
            buyoutCount = book.buyoutCount,
            bidOnlyCount = book.bidOnlyCount,
            totalUnits = book.totalUnits,
            itemKinds = itemKinds,
            pages = pageKinds,
        }
    end

    function api.stats()
        local books = 0
        for _ in pairs(state.books) do books = books + 1 end
        return { books = books, nextGeneration = state.nextGeneration }
    end

    return api
end)
if not ok then error(R.lastHotError or "marketbook replacement failed") end
