!AutoJunkLock v3 — WoW 1.12

POPRAWKA KRYTYCZNA
Poprzednia wersja mogła wykonać UseContainerItem nawet wtedy, gdy próba
uruchomienia Pick Lock nie weszła w tryb wyboru celu.

v3 robi to bezpiecznie:
1. wykrywa zamknięty junkbox,
2. uruchamia Pick Lock z konkretnego slotu spellbooka,
3. sprawdza SpellIsTargeting(),
4. tylko jeśli Pick Lock naprawdę czeka na cel, używa junkboxa jako celu,
5. jeśli sorter przesunie item, operacja jest anulowana i skan zaczyna się od nowa,
6. zwykłe otwarcie jest dozwolone tylko dla tooltipa potwierdzonego jako UNLOCKED.

Addon nie działa w combacie.

Test:
  /ajl debug
  /ajl scan

Dla zamkniętego boxa:
  state=LOCKED
następnie:
  PICK target item=...

Nie powinno być OPEN dla skrzynki ze state=LOCKED.

Komendy:
  /ajl on
  /ajl off
  /ajl debug
  /ajl scan
  /ajl loot on
  /ajl loot off
  /ajl
