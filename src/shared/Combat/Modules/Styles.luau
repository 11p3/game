local Styles = {
    Boxing = {
        Name = "Boxing",
        FighterId = "Boxing",
        Order = 1,
        Description = "Fast hands. Hooks, feints and body shots.",
        Controls = "Left click: jab  •  C: lead hook  •  Q: feint  •  V: clinch / click: shove  •  E: dodge / escape  •  F: guard  •  R: gut punch",
        SpecialName = "GUT",
        MoveGuide = {
            {
                Key = "Left click",
                Name = "Jab",
                Move = "Jab",
                Description = "A quick punch. Landed jabs chain into faster follow-ups; the opening jab hits harder.",
                Use = "Click in range, then time another jab after a hit. Misses and blocks leave committed recovery."
            },
            {
                Key = "C",
                Name = "Lead hook",
                Move = "LeadHook",
                Description = "A short, wide punch. Costs more stamina than a jab and deals extra damage against attack recovery.",
                Use = "Close the gap to catch circling or punish a miss. Whiffs and blocks leave committed recovery; it has its own cooldown."
            },
            {
                Key = "Q",
                Name = "Feint",
                Move = "Feint",
                Description = "Show a punch windup without dealing damage. A feint cannot grant a perfect dodge.",
                Use = "Bait an early dodge, then punish the opponent's recovery with a real attack."
            },
            {
                Key = "R",
                Name = "Gut punch",
                Move = "GutPunch",
                Description = "Spend three momentum charges on a stronger body punch that briefly stuns on a clean hit.",
                Use = "Build charge through clean hits. A landed jab can confirm into a quicker gut punch. Drive a clean hit into Arena’s cage for a wall splat and a follow-up."
            },
            {
                Key = "Left click · controlling clinch",
                Name = "Clinch shove",
                Move = "ClinchShove",
                Description = "Push the opponent away and end the clinch. The shove creates space without dealing damage.",
                Use = "Grab with V, then click to create space or drive them into Arena’s cage for a wall splat."
            },
        },
    },

    MuayThai = {
        Name = "Muay Thai",
        FighterId = "MuayThai",
        Order = 2,
        Description = "Long kicks. Knees and guard pressure.",
        Controls = "Left click: jab  •  C: low kick  •  Q: body kick  •  V: clinch / click: knee  •  E: dodge / escape  •  F: guard  •  R: knee string",
        SpecialName = "KNEE",
        MoveGuide = {
            {
                Key = "Left click",
                Name = "Jab",
                Move = "Jab",
                Description = "A longer-reaching jab with slower chains than Boxing.",
                Use = "Use its reach to catch approaches, then follow a clean hit with pressure."
            },
            {
                Key = "C",
                Name = "Low kick",
                Move = "LowKick",
                Description = "A quick, long-reaching kick with committed recovery and its own cooldown.",
                Use = "Catch opponents near the edge of punch range. A clean kick can confirm into the knee special."
            },
            {
                Key = "Q",
                Name = "Body kick",
                Move = "BodyKick",
                Description = "A stronger kick that pressures the block meter and can confirm into knees.",
                Use = "Pressure guard or drive a clean hit into Arena’s cage for a wall splat and a follow-up. A miss leaves time for a counter."
            },
            {
                Key = "R",
                Name = "Knee string",
                Move = "Knee",
                Description = "Spend three momentum charges on two knee strikes. The final clean hit briefly stuns.",
                Use = "Build charge, close the gap, then press R. A landed low or body kick can speed up the entry."
            },
            {
                Key = "Left click · controlling clinch",
                Name = "Clinch knee",
                Move = "ClinchKnee",
                Description = "Knee the held opponent without immediately ending the clinch.",
                Use = "Grab with V, then time clicks for knees. Watch your stamina and the opponent's escape attempts."
            },
        },
    },
    Wrestling = {
        Name = "Wrestling",
        FighterId = "Wrestling",
        Order = 3,
        Description = "Close the gap. Grab, trip, and throw.",
        Controls = "Click: jab / clinch trip · Q: shoot · C: single leg · R: clinch suplex\nV: clinch / release · E: dodge / escape or reverse · F: guard",
        SpecialName = "SUPLEX",
        MoveGuide = {
            {
                Key = "Left click",
                Name = "Jab",
                Move = "Jab",
                Description = "A lighter jab that builds momentum for your suplex.",
                Use = "Use it to interrupt approaches and build charge before attempting a grab."
            },
            {
                Key = "Q",
                Name = "Shoot",
                Move = "Shoot",
                Description = "Lunge forward and capture a nearby opponent in a longer clinch. The shoot bypasses guard but can be dodged.",
                Use = "Use at close to medium range to enter your grappling moves. A missed shoot has punishable recovery."
            },
            {
                Key = "C",
                Name = "Single leg",
                Move = "SingleLeg",
                Description = "A standalone takedown that bypasses guard, deals damage, and briefly stuns. It can be dodged.",
                Use = "Press C in range without needing a clinch. Drive the opponent into Arena’s cage for a wall splat; the move still has a cooldown."
            },
            {
                Key = "R · controlling clinch",
                Name = "Suplex",
                Move = "Suplex",
                Description = "Spend three momentum charges on a damaging paired throw that ends the clinch.",
                Use = "Build charge with clean hits, grab with Q or V, then press R while controlling the clinch."
            },
            {
                Key = "E / V / click · held in clinch",
                Name = "Reversal",
                Description = "Fill the escape bar to take control instead of releasing. Each clinch allows one reversal.",
                Use = "Tap after the opening lock. Once reversed, attack or release; the next successful escape ends the clinch."
            },
            {
                Key = "Left click · controlling clinch",
                Name = "Clinch trip",
                Move = "ClinchTrip",
                Description = "Trip the held opponent for damage and a brief stun, then release them.",
                Use = "Enter a clinch and click to trip them, or drive them into Arena’s cage for a wall splat and a follow-up."
            },
        },
    },
}

for _, style in Styles do
    table.insert(style.MoveGuide, {Key = "F · timed guard", Name = "Kick catch", Description = "Tap guard just before a low kick or body kick connects to catch it and take clinch control. Costs stamina; punches and knees are blocked normally.", Use = "Time a fresh F press near contact. Holding guard early only blocks. Catch attempts have a two-second cooldown; normal guard remains available. Follow a catch with your style's clinch attack or special."})
end

return Styles
