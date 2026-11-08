-- Each map declares its crowd and lighting rules for local presentation.
local Maps = {
    Arena = {
        Name = "Arena",
        Description = "Indoor MMA venue with a live crowd.",
        Order = 1,
        Fans = true,
    },
    Desert = {
        Name = "Desert",
        Description = "A weathered training yard surrounded by canyon walls.",
        Order = 2,
        Fans = false,
        Lighting = {
            ClockTime = 16.1,
            Brightness = 2.1,
            Ambient = Color3.fromRGB(110, 101, 86),
            OutdoorAmbient = Color3.fromRGB(145, 132, 110),
            FogColor = Color3.fromRGB(205, 181, 145),
            FogStart = 65,
            FogEnd = 580
        },
    },
    Rooftop = {
        Name = "Rooftop",
        Description = "A rooftop training court above a layered city skyline.",
        Order = 3,
        Fans = false,
        Lighting = {
            ClockTime = 17.4,
            Brightness = 2,
            Ambient = Color3.fromRGB(113, 119, 135),
            OutdoorAmbient = Color3.fromRGB(137, 145, 162),
            FogColor = Color3.fromRGB(154, 165, 184),
            FogStart = 80,
            FogEnd = 650
        },
    },
}

return Maps
