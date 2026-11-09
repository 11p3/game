# game

## Research references

- [GGPO — Rollback Networking SDK](https://www.ggpo.net/), by Tony Cannon. Reference for deterministic simulation, input prediction, saved state, and re-simulating frames when received inputs differ from predictions. These ideas inform `RollbackSession` and the shared fight simulation.
- [How 2XKO Handles Online Play](https://2xko.riotgames.com/en-us/news/dev/how-2xko-handles-online-play/), by Tony “Riot Pond3r” Cannon, Riot Games. Reference for server authority over inputs, state and time, bounded input grace, and fixed input delay. These ideas inform the combat transport and rollback timing policy.

The rollback runtime is a custom Luau implementation informed by these references. It does not use the GGPO SDK or Riot's implementation. The project's timing values and gameplay rules are its own tuning choices, rather than values prescribed by those sources.
