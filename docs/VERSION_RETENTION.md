# Version retention

Repozytorium przechowuje pelna historie wersji roboczych projektu WoW 1.12.1 build 5875.

## Regula

- Nie ma sztywnego limitu liczby zachowanych wersji.
- Kazdy kolejny stabilny baseline pozostaje w repo jako punkt rollbacku i material porownawczy.
- `CURRENT_VERSION.md` zawsze wskazuje aktywny baseline.
- Poprzednie wersje pozostaja dostepne i nie sa automatycznie usuwane po wydaniu nowszej wersji.
- Dla kazdej wersji priorytet maja: runtime, dostepne source, SHA256, README/changelog i skrypty verify/cleanup.
- Stare wersje mozna oznaczac jako deprecated, ale nie usuwamy ich tylko z powodu wieku.
- Usuwanie historycznych artefaktow wykonujemy tylko swiadomie, np. gdy plik jest uszkodzony, zdublowany albo jednoznacznie zbedny technicznie.

## Current

V68 jest aktualnym baseline. V67 pozostaje bezposrednim rollbackiem. Kolejne V69, V70 itd. beda zachowywane razem z poprzednimi wersjami bez automatycznej rotacji.
