#!/usr/bin/env python3
"""Generate the WEL Bank seed script: database/seed/build/seed.sql.

Synthetic people and two years of banking activity, shaped by the Ghana
Statistical Service's 2021 Population and Housing Census (data/census_*.csv):
regions, ethnic groups by region, adult ages and sexes, and non-Ghanaian
nationalities. The v1 staff and customers (data/v1_*.csv) are kept.

Everything is deterministic: the same arguments always produce the same file
(random.Random(SEED) here, DBMS_RANDOM.SEED in sql/simulate_month.sql).

Nothing here talks to the database. The generated script calls the PL/SQL
packages (pkg_customer, pkg_account, pkg_posting, pkg_loan), so the seed
obeys every business rule, exactly like the web app will.

Usage (normally through ./scripts/db-seed.sh):
    python3 database/seed/generate_seed.py [--customers 2000] [--months 24]
"""

import argparse
import csv
import datetime as dt
import hashlib
import json
import random
import struct
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
DATA = HERE / "data"
BUILD = HERE / "build"
SQL_DIR = "/opt/welbank/database/seed/sql"  # where the container sees database/seed/sql
SEED = 20261112

# ---------------------------------------------------------------------------- census


def read_csv(name):
    with open(DATA / name, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


REGIONS = read_csv("census_2021_regions.csv")
ETHNICITY = read_csv("census_2021_ethnicity_by_region.csv")
AGES = read_csv("census_2021_adults_by_age_sex.csv")
NON_GHANAIANS = read_csv("census_2021_non_ghanaians.csv")

# ---------------------------------------------------------------------------- names
# Common names by ethnic group (illustrative lists, not census data). Akan
# children are named after their day of birth, so Akan first names follow the
# generated date of birth: Python's weekday() is 0 = Monday.
AKAN_DAY = {
    0: ("Kwadwo", "Adwoa"),
    1: ("Kwabena", "Abena"),
    2: ("Kwaku", "Akua"),
    3: ("Yaw", "Yaa"),
    4: ("Kofi", "Afua"),
    5: ("Kwame", "Ama"),
    6: ("Kwesi", "Akosua"),
}
CHRISTIAN = {
    "MALE": [
        "Emmanuel",
        "Samuel",
        "Daniel",
        "Isaac",
        "Joseph",
        "Michael",
        "Francis",
        "Richard",
        "Prince",
        "Eric",
        "Stephen",
        "Godfred",
        "Benjamin",
        "Solomon",
        "Ebenezer",
        "Felix",
        "George",
        "Patrick",
        "Bernard",
        "Collins",
    ],
    "FEMALE": [
        "Grace",
        "Mercy",
        "Comfort",
        "Gifty",
        "Patience",
        "Esther",
        "Rita",
        "Joyce",
        "Linda",
        "Priscilla",
        "Vida",
        "Doris",
        "Felicia",
        "Beatrice",
        "Elizabeth",
        "Matilda",
        "Agnes",
        "Dorcas",
        "Juliana",
        "Sandra",
    ],
}
MUSLIM = {
    "MALE": [
        "Mohammed",
        "Abdulai",
        "Alhassan",
        "Issah",
        "Iddrisu",
        "Fuseini",
        "Salifu",
        "Yakubu",
        "Zakaria",
        "Ibrahim",
        "Mumuni",
        "Seidu",
        "Abubakari",
        "Osman",
        "Yussif",
    ],
    "FEMALE": [
        "Amina",
        "Fatima",
        "Mariama",
        "Ayishetu",
        "Hawa",
        "Rabi",
        "Memunatu",
        "Zenabu",
        "Abiba",
        "Sana",
        "Rahinatu",
        "Barikisu",
        "Salamatu",
        "Hajara",
        "Adisa",
    ],
}
LOCAL_FIRST = {
    "Ewe": {
        "MALE": [
            "Elikem",
            "Selorm",
            "Senyo",
            "Edem",
            "Komla",
            "Kodzo",
            "Kwami",
            "Yao",
            "Kossi",
            "Mawuli",
        ],
        "FEMALE": [
            "Esinam",
            "Dzifa",
            "Enyonam",
            "Akpene",
            "Mawusi",
            "Delali",
            "Sena",
            "Afi",
            "Abla",
            "Elinam",
        ],
    },
    "Ga-Dangme": {
        "MALE": ["Nii", "Nii Armah", "Nii Lante", "Tetteh", "Ashie", "Nortey", "Odartey", "Teiko"],
        "FEMALE": [
            "Naa",
            "Naa Adjeley",
            "Dedei",
            "Korkor",
            "Akweley",
            "Adoley",
            "Lamiley",
            "Shormeh",
        ],
    },
}
SURNAMES = {
    "Akan": [
        "Mensah",
        "Owusu",
        "Asante",
        "Boateng",
        "Osei",
        "Appiah",
        "Acheampong",
        "Amoah",
        "Agyeman",
        "Ansah",
        "Danquah",
        "Frimpong",
        "Gyamfi",
        "Kyei",
        "Ofori",
        "Opoku",
        "Sarpong",
        "Adjei",
        "Bonsu",
        "Antwi",
        "Darko",
        "Badu",
        "Amponsah",
        "Asamoah",
        "Yeboah",
        "Addai",
        "Nyarko",
        "Amankwah",
        "Oppong",
        "Kwarteng",
    ],
    "Mole-Dagbani": [
        "Mahama",
        "Alhassan",
        "Abdulai",
        "Iddrisu",
        "Yakubu",
        "Seidu",
        "Sulemana",
        "Dawuda",
        "Yahaya",
        "Zakaria",
        "Abubakari",
        "Baba",
        "Bawa",
        "Osman",
        "Wumbei",
        "Tia",
        "Sumani",
        "Haruna",
    ],
    "Ewe": [
        "Agbeko",
        "Dzeble",
        "Kpodo",
        "Amegashie",
        "Ahiadeke",
        "Ahadzie",
        "Gbeho",
        "Kudjawu",
        "Tsikata",
        "Agbenyega",
        "Avevor",
        "Dogbe",
        "Dzokoto",
        "Fiagbe",
        "Klutse",
        "Gadzekpo",
        "Amedzro",
        "Ketsekpor",
    ],
    "Ga-Dangme": [
        "Tetteh",
        "Quaye",
        "Lamptey",
        "Nortey",
        "Ashitey",
        "Ankrah",
        "Adjetey",
        "Okine",
        "Laryea",
        "Sowah",
        "Kotey",
        "Odoi",
        "Lartey",
        "Tagoe",
        "Abbey",
        "Nartey",
        "Mensah-Bonsu",
    ],
    "Gurma": [
        "Nambe",
        "Biyimba",
        "Kpandja",
        "Yaja",
        "Nabiche",
        "Ngulimi",
        "Bigmaa",
        "Konlan",
        "Jagri",
        "Bitiir",
    ],
    "Guan": [
        "Jakpa",
        "Kpabi",
        "Jinapor",
        "Mumuni",
        "Larbi",
        "Ofosu",
        "Kumah",
        "Gyasi",
        "Anane",
        "Awuah",
    ],
    "Grusi": [
        "Akurugu",
        "Atanga",
        "Ayamga",
        "Abanga",
        "Akolgo",
        "Awuni",
        "Asaba",
        "Ayine",
        "Adongo",
        "Akanbonga",
    ],
    "Mande": ["Bugri", "Kambuna", "Cisse", "Kamara", "Bawa", "Zangina", "Wangara", "Konate"],
    "Others": [
        "Mensah",
        "Addo",
        "Annan",
        "Quansah",
        "Arthur",
        "Essien",
        "Hagan",
        "Ackah",
        "Kwofie",
        "Aidoo",
    ],
}
MUSLIM_SHARE = {"Mole-Dagbani": 0.65, "Gurma": 0.25, "Grusi": 0.35, "Mande": 0.8, "Guan": 0.3}
FOREIGN = {  # code: (country, nationality, is_ecowas, risk, male first, female first, surnames)
    "NGA": (
        "Nigeria",
        "Nigerian",
        True,
        "MEDIUM",
        ["Chukwuemeka", "Oluwaseun", "Ifeanyi", "Tunde", "Emeka"],
        ["Ifeoma", "Ngozi", "Funmilayo", "Chiamaka", "Bisola"],
        ["Okafor", "Adeyemi", "Okonkwo", "Balogun", "Eze", "Bello"],
    ),
    "TGO": (
        "Togo",
        "Togolese",
        True,
        "LOW",
        ["Komlan", "Kossi", "Kodjo", "Yawo"],
        ["Akouvi", "Afiwa", "Kafui", "Ablavi"],
        ["Agbodjan", "Adjovi", "Lawson", "Amouzou", "Gnassingbe"],
    ),
    "BFA": (
        "Burkina Faso",
        "Burkinabe",
        True,
        "MEDIUM",
        ["Ousmane", "Salif", "Issouf", "Boukary"],
        ["Aminata", "Salimata", "Awa"],
        ["Ouedraogo", "Sawadogo", "Compaore", "Kabore", "Zongo"],
    ),
    "CIV": (
        "Cote d'Ivoire",
        "Ivorian",
        True,
        "LOW",
        ["Kouassi", "Yao", "Kouakou", "Serge"],
        ["Adjoua", "Affoue", "Mariam"],
        ["Konan", "Kouame", "Traore", "Koffi", "Diomande"],
    ),
    "LBR": (
        "Liberia",
        "Liberian",
        True,
        "MEDIUM",
        ["Momo", "Prince", "Varney"],
        ["Musu", "Comfort", "Hawa"],
        ["Johnson", "Kollie", "Flomo", "Sirleaf"],
    ),
    "SLE": (
        "Sierra Leone",
        "Sierra Leonean",
        True,
        "MEDIUM",
        ["Mohamed", "Abu", "Foday"],
        ["Isatu", "Kadiatu"],
        ["Kamara", "Sesay", "Bangura"],
    ),
    "GMB": (
        "Gambia",
        "Gambian",
        True,
        "LOW",
        ["Lamin", "Ebrima"],
        ["Fatou", "Isatou"],
        ["Jallow", "Ceesay", "Touray"],
    ),
    "BEN": (
        "Benin",
        "Beninese",
        True,
        "LOW",
        ["Codjo", "Sossou"],
        ["Ayaba", "Sika"],
        ["Houngbo", "Agossou", "Dossou"],
    ),
    "NER": (
        "Niger",
        "Nigerien",
        True,
        "HIGH",
        ["Moussa", "Abdou"],
        ["Aissa", "Hadiza"],
        ["Maiga", "Issoufou", "Garba"],
    ),
    "MLI": (
        "Mali",
        "Malian",
        True,
        "HIGH",
        ["Bakary", "Modibo"],
        ["Kadidia", "Oumou"],
        ["Keita", "Diallo", "Coulibaly"],
    ),
    "SEN": (
        "Senegal",
        "Senegalese",
        True,
        "LOW",
        ["Cheikh", "Mamadou"],
        ["Awa", "Ndeye"],
        ["Ndiaye", "Diop", "Fall"],
    ),
    "CMR": (
        "Cameroon",
        "Cameroonian",
        False,
        "MEDIUM",
        ["Jean-Paul", "Thierry"],
        ["Brigitte", "Sandrine"],
        ["Mbarga", "Fotso", "Ngono"],
    ),
    "ZAF": (
        "South Africa",
        "South African",
        False,
        "LOW",
        ["Thabo", "Sipho"],
        ["Thandiwe", "Lerato"],
        ["Nkosi", "Dlamini", "van Wyk"],
    ),
    "KEN": (
        "Kenya",
        "Kenyan",
        False,
        "LOW",
        ["Otieno", "Kamau"],
        ["Wanjiru", "Achieng"],
        ["Odhiambo", "Mwangi", "Kiprono"],
    ),
    "USA": (
        "United States",
        "American",
        False,
        "LOW",
        ["James", "Michael", "David"],
        ["Emily", "Sarah", "Jessica"],
        ["Smith", "Johnson", "Williams", "Brown"],
    ),
    "CAN": (
        "Canada",
        "Canadian",
        False,
        "LOW",
        ["Liam", "Noah"],
        ["Olivia", "Emma"],
        ["Tremblay", "Martin", "Roy"],
    ),
    "BRA": (
        "Brazil",
        "Brazilian",
        False,
        "LOW",
        ["Lucas", "Mateus"],
        ["Ana", "Beatriz"],
        ["Silva", "Santos", "Oliveira"],
    ),
    "CHN": (
        "China",
        "Chinese",
        False,
        "LOW",
        ["Wei", "Jun", "Hao", "Lei"],
        ["Li Na", "Mei", "Xiu Ying", "Fang"],
        ["Wang", "Li", "Zhang", "Chen", "Liu"],
    ),
    "IND": (
        "India",
        "Indian",
        False,
        "LOW",
        ["Rahul", "Arjun", "Vikram"],
        ["Priya", "Anjali", "Deepa"],
        ["Sharma", "Patel", "Nair", "Reddy"],
    ),
    "LBN": (
        "Lebanon",
        "Lebanese",
        False,
        "MEDIUM",
        ["Ali", "Karim", "Fadi"],
        ["Rania", "Nour", "Layla"],
        ["Haddad", "Khoury", "Saade"],
    ),
    "PHL": (
        "Philippines",
        "Filipino",
        False,
        "LOW",
        ["Jose", "Mark"],
        ["Maria", "Joy"],
        ["Santos", "Reyes", "Cruz"],
    ),
    "GBR": (
        "United Kingdom",
        "British",
        False,
        "LOW",
        ["Oliver", "Harry", "George"],
        ["Charlotte", "Amelia", "Sophie"],
        ["Taylor", "Brown", "Wilson", "Evans"],
    ),
    "DEU": (
        "Germany",
        "German",
        False,
        "LOW",
        ["Lukas", "Felix"],
        ["Marie", "Anna"],
        ["Muller", "Schmidt", "Weber"],
    ),
    "FRA": (
        "France",
        "French",
        False,
        "LOW",
        ["Louis", "Hugo"],
        ["Camille", "Chloe"],
        ["Martin", "Bernard", "Dubois"],
    ),
    "NLD": (
        "Netherlands",
        "Dutch",
        False,
        "LOW",
        ["Daan", "Sem"],
        ["Emma", "Julia"],
        ["de Jong", "Jansen", "Bakker"],
    ),
    "AUS": (
        "Australia",
        "Australian",
        False,
        "LOW",
        ["Jack", "William"],
        ["Chloe", "Mia"],
        ["Smith", "Jones", "Kelly"],
    ),
}
# Census groups -> the countries that stand for them in the seed.
GROUP_COUNTRIES = {
    "BFA": ["BFA"],
    "CIV": ["CIV"],
    "GMB": ["GMB"],
    "LBR": ["LBR"],
    "NGA": ["NGA"],
    "SLE": ["SLE"],
    "TGO": ["TGO"],
    "ECOWAS_OTHER": ["BEN", "NER", "MLI", "SEN"],
    "AFRICA_OTHER": ["CMR", "ZAF", "KEN"],
    "AMERICAS": ["USA", "CAN", "BRA"],
    "ASIA": ["CHN", "IND", "LBN", "PHL"],
    "EUROPE": ["GBR", "DEU", "FRA", "NLD"],
    "OCEANIA": ["AUS"],
}

TOWNS = {
    "Western": ["Sekondi-Takoradi", "Tarkwa", "Axim", "Prestea"],
    "Central": ["Cape Coast", "Kasoa", "Winneba", "Mankessim"],
    "Greater Accra": [
        "Accra",
        "Tema",
        "Madina",
        "Adenta",
        "Ashaiman",
        "Dansoman",
        "Teshie",
        "East Legon",
    ],
    "Volta": ["Ho", "Keta", "Hohoe", "Aflao"],
    "Eastern": ["Koforidua", "Nkawkaw", "Akim Oda", "Nsawam"],
    "Ashanti": ["Kumasi", "Obuasi", "Ejisu", "Konongo", "Mampong"],
    "Western North": ["Sefwi Wiawso", "Bibiani", "Enchi"],
    "Ahafo": ["Goaso", "Bechem", "Kenyasi"],
    "Bono": ["Sunyani", "Berekum", "Dormaa Ahenkro"],
    "Bono East": ["Techiman", "Kintampo", "Atebubu"],
    "Oti": ["Dambai", "Jasikan", "Nkwanta"],
    "Northern": ["Tamale", "Yendi", "Savelugu"],
    "Savannah": ["Damongo", "Bole", "Salaga"],
    "North East": ["Nalerigu", "Walewale"],
    "Upper East": ["Bolgatanga", "Navrongo", "Bawku"],
    "Upper West": ["Wa", "Tumu", "Lawra"],
}
GPS = {
    "Western": "WS",
    "Central": "CC",
    "Greater Accra": "GA",
    "Volta": "VH",
    "Eastern": "EN",
    "Ashanti": "AK",
    "Western North": "WN",
    "Ahafo": "AH",
    "Bono": "BS",
    "Bono East": "BT",
    "Oti": "OT",
    "Northern": "NT",
    "Savannah": "SD",
    "North East": "NE",
    "Upper East": "UB",
    "Upper West": "XW",
}
# Branches: the two v1 branches first (East Legon, Ho), then one per region at least.
BRANCHES = [
    ("ACC-ELG", "East Legon", "Greater Accra", "Lagos Avenue", "East Legon"),
    ("HO-MAIN", "Ho", "Volta", "Ho Road", "Ho"),
    ("ACC-CEN", "Accra Central", "Greater Accra", "High Street", "Accra"),
    ("TEM-C1", "Tema Community 1", "Greater Accra", "Harbour Road", "Tema"),
    ("KSI-ADM", "Kumasi Adum", "Ashanti", "Prempeh II Street", "Kumasi"),
    ("KSI-KNS", "Kumasi KNUST", "Ashanti", "University Road", "Kumasi"),
    ("OBU-MAIN", "Obuasi", "Ashanti", "Mine Road", "Obuasi"),
    ("TKD-MKT", "Takoradi Market Circle", "Western", "Market Circle", "Sekondi-Takoradi"),
    ("CCT-MAIN", "Cape Coast", "Central", "Commercial Street", "Cape Coast"),
    ("KAS-MAIN", "Kasoa", "Central", "Winneba Road", "Kasoa"),
    ("KOF-MAIN", "Koforidua", "Eastern", "Zongo Junction", "Koforidua"),
    ("TML-MAIN", "Tamale", "Northern", "Bolgatanga Road", "Tamale"),
    ("BLG-MAIN", "Bolgatanga", "Upper East", "Navrongo Road", "Bolgatanga"),
    ("WA-MAIN", "Wa", "Upper West", "Kpaguri Road", "Wa"),
    ("SUN-MAIN", "Sunyani", "Bono", "Fiapre Road", "Sunyani"),
    ("TCH-MAIN", "Techiman", "Bono East", "Market Road", "Techiman"),
    ("GOA-MAIN", "Goaso", "Ahafo", "Kumasi Road", "Goaso"),
    ("DMG-MAIN", "Damongo", "Savannah", "Station Road", "Damongo"),
    ("NAL-MAIN", "Nalerigu", "North East", "Gambaga Road", "Nalerigu"),
    ("DAM-MAIN", "Dambai", "Oti", "Ferry Road", "Dambai"),
    ("SWW-MAIN", "Sefwi Wiawso", "Western North", "Bibiani Road", "Sefwi Wiawso"),
]
BRANCH_STAFF = [
    ("Branch manager", 1),
    ("Teller supervisor", 1),
    ("Bank teller", 2),
    ("Customer service representative", 1),
    ("Loan officer", 1),
]
OCCUPATIONS = {
    "EMPLOYED": [
        "Teacher",
        "Nurse",
        "Civil servant",
        "Accountant",
        "Engineer",
        "Police officer",
        "Sales executive",
        "Driver",
        "Security officer",
        "Pharmacist",
        "Lecturer",
        "Bank officer",
        "Clerk",
        "Soldier",
    ],
    "SELF_EMPLOYED": [
        "Trader",
        "Farmer",
        "Cocoa farmer",
        "Seamstress",
        "Hairdresser",
        "Mechanic",
        "Carpenter",
        "Tailor",
        "Fishmonger",
        "Shop owner",
        "Caterer",
        "Electrician",
        "Okada rider",
        "Builder",
    ],
    "STUDENT": ["Student"],
    "RETIRED": ["Retired"],
    "UNEMPLOYED": ["Unemployed"],
}
EMPLOYERS = [
    "Ghana Education Service",
    "Ghana Health Service",
    "Ghana Police Service",
    "Electricity Company of Ghana",
    "MTN Ghana",
    "Cocobod",
    "Ghana Revenue Authority",
    "University of Ghana",
    "KNUST",
    "Melcom",
    "Shoprite Ghana",
]
INCOME = {"UNDER_1K": 700, "1K_5K": 3000, "5K_10K": 7500, "10K_50K": 20000, "OVER_50K": 65000}
PEP_ROLES = [
    "Member of Parliament",
    "District Chief Executive",
    "High Court judge",
    "Deputy Minister",
    "Regional Minister",
]
LANDMARKS = [
    "Behind the Methodist church",
    "Near the lorry station",
    "Opposite the police station",
    "Close to the market",
    "Next to the junior high school",
    "Near the chief's palace",
    "Behind the filling station",
    "Off the main road",
]

# ---------------------------------------------------------------------------- helpers


def q(value):
    """A SQL literal: quoted and escaped text, or NULL."""
    if value is None:
        return "NULL"
    return "'" + str(value).replace("'", "''") + "'"


def d(day):
    return f"DATE '{day:%Y-%m-%d}'"


def b(flag):
    return "TRUE" if flag else "FALSE"


def add_months(day, months):
    """The same day-of-month (capped at 28) some months later."""
    total = day.year * 12 + day.month - 1 + months
    return dt.date(total // 12, total % 12 + 1, min(day.day, 28))


def weighted(rng, items, weights):
    return rng.choices(items, weights=weights, k=1)[0]


def png(width, height, rows, color_type):
    """A PNG file from raw rows (bytes per row), written with zlib only."""

    def chunk(kind, data):
        return (
            struct.pack(">I", len(data))
            + kind
            + data
            + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
        )

    raw = b"".join(b"\x00" + row for row in rows)  # filter byte 0 (none) before every row
    header = struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def avatar(rng):
    """A 48x48 synthetic portrait: background, head, hair and shoulders."""
    bg = rng.choice(
        [(214, 228, 240), (232, 222, 210), (220, 236, 220), (240, 226, 232), (226, 224, 242)]
    )
    skin = rng.choice(
        [
            (92, 58, 38),
            (120, 78, 50),
            (141, 92, 60),
            (166, 116, 78),
            (198, 150, 110),
            (225, 190, 160),
        ]
    )
    hair = rng.choice([(20, 16, 14), (40, 30, 24), (60, 44, 30), (90, 70, 50)])
    shirt = rng.choice(
        [(40, 70, 140), (150, 40, 50), (40, 120, 80), (200, 160, 40), (90, 60, 130), (60, 60, 60)]
    )
    hair_top = rng.randint(6, 10)
    rows = []
    for y in range(48):
        row = bytearray()
        for x in range(48):
            colour = bg
            if (x - 24) ** 2 / 18**2 + (y - 50) ** 2 / 15**2 <= 1:
                colour = shirt
            if (x - 24) ** 2 + (y - 20) ** 2 <= 11**2:
                colour = hair if y < 20 - 11 + hair_top else skin
            row += bytes(colour)
        rows.append(bytes(row))
    return png(48, 48, rows, 2)


def signature(rng):
    """A 120x36 grey-scale scribble that looks like a handwritten signature."""
    import math

    a1, a2, p = rng.uniform(0.08, 0.2), rng.uniform(0.2, 0.45), rng.uniform(0, 6.28)
    pixels = [[255] * 120 for _ in range(36)]
    prev = None
    for x10 in range(80, 1120):
        x = x10 / 10
        y = 18 + 8 * math.sin(a1 * x + p) + 5 * math.sin(a2 * x) * math.exp(-(((x - 40) / 60) ** 2))
        point = (int(x), int(y))
        if point != prev:
            for dx in (0, 1):
                for dy in (0, 1):
                    xx, yy = point[0] + dx, point[1] + dy
                    if 0 <= xx < 120 and 0 <= yy < 36:
                        pixels[yy][xx] = 30
            prev = point
    return png(120, 36, [bytes(r) for r in pixels], 0)


def blob(data):
    """TO_BLOB(HEXTORAW(...)) with the hex text split into short lines (SQL*Plus line limit)."""
    hexed = data.hex().upper()
    parts = [hexed[i : i + 900] for i in range(0, len(hexed), 900)]
    return "TO_BLOB(HEXTORAW('" + "'\n      || '".join(parts) + "'))"


# ---------------------------------------------------------------------------- people


class Generator:
    def __init__(self, customers, months):
        self.rng = random.Random(SEED)
        self.customers_wanted = customers
        self.months = months
        # First day of the first simulated month: the history ends with last month.
        self.start = add_months(dt.date.today().replace(day=1), -months)
        self.used_cards, self.used_emails, self.serial = set(), set(), 0
        self.employees, self.customers = [], []

    # -- small random pieces
    def phone(self):
        return (
            "+233"
            + self.rng.choice(["24", "54", "55", "59", "20", "50", "26", "56", "27", "57"])
            + f"{self.rng.randint(0, 9999999):07d}"
        )

    def card(self, prefix="GHA"):
        while True:
            body = f"{self.rng.randint(1, 999999999):09d}"
            number = f"GHA-{body}-{self.rng.randint(0, 9)}" if prefix == "GHA" else f"NC-{body}"
            if number not in self.used_cards:
                self.used_cards.add(number)
                return number

    def email(self, first, last, domain="example.com"):
        base = "".join(
            ch for ch in f"{first}.{last}".lower().replace(" ", ".") if ch.isalnum() or ch == "."
        )
        email, n = f"{base}@{domain}", 1
        while email in self.used_emails:
            n += 1
            email = f"{base}{n}@{domain}"
        self.used_emails.add(email)
        return email

    def digital_address(self, region):
        return f"{GPS[region]}-{self.rng.randint(100, 9999):03d}-{self.rng.randint(0, 9999):04d}"

    def age_and_sex(self):
        row = weighted(self.rng, AGES, [int(r["both_sexes"]) for r in AGES])
        age = 95 + self.rng.randint(0, 4) if row["age"] == "95+" else int(row["age"])
        sex = "MALE" if self.rng.random() < int(row["male"]) / int(row["both_sexes"]) else "FEMALE"
        return age, sex

    def birth_date(self, age, on_day):
        start = on_day.replace(year=on_day.year - age - 1) + dt.timedelta(days=1)
        return start + dt.timedelta(days=self.rng.randint(0, 360))

    def ghanaian_name(self, ethnic, sex, dob):
        if ethnic == "Akan":
            first = AKAN_DAY[dob.weekday()][0 if sex == "MALE" else 1]
            middle = self.rng.choice(CHRISTIAN[sex]) if self.rng.random() < 0.5 else None
            if middle and self.rng.random() < 0.5:
                first, middle = middle, first  # many people use the Christian name first
        elif self.rng.random() < MUSLIM_SHARE.get(ethnic, 0.05):
            first, middle = self.rng.choice(MUSLIM[sex]), None
        elif ethnic in LOCAL_FIRST and self.rng.random() < 0.5:
            first, middle = self.rng.choice(LOCAL_FIRST[ethnic][sex]), None
        else:
            first, middle = self.rng.choice(CHRISTIAN[sex]), None
        return first, middle, self.rng.choice(SURNAMES[ethnic])

    # -- the population
    def build_people(self):
        v1_customers = read_csv("v1_customers.csv")
        foreign_total = max(
            round(self.customers_wanted * 0.009), 40
        )  # census: 0.9 %; at least 40 so every group shows
        group_weights = [int(g["population"]) for g in NON_GHANAIANS]
        region_weights = [int(r["population"]) for r in REGIONS]
        for i in range(self.customers_wanted - len(v1_customers)):
            month = min(
                self.months - 1, int(self.months * self.rng.random() ** 0.8)
            )  # more customers in later months
            when = add_months(self.start, month) + dt.timedelta(days=self.rng.randint(0, 27))
            age, sex = self.age_and_sex()
            dob = self.birth_date(age, when)
            person = {"month": month, "sex": sex, "dob": dob, "age": age}
            if i < foreign_total:
                group = weighted(self.rng, NON_GHANAIANS, group_weights)["code"]
                code = self.rng.choice(GROUP_COUNTRIES[group])
                country, _, ecowas, risk, males, females, surnames = FOREIGN[code]
                person.update(
                    nationality=code,
                    first=self.rng.choice(males if sex == "MALE" else females),
                    middle=None,
                    last=self.rng.choice(surnames),
                    doc_type="NON_CITIZEN_CARD",
                    doc=self.card("NC"),
                    region="Greater Accra"
                    if self.rng.random() < 0.6
                    else weighted(self.rng, REGIONS, region_weights)["region"],
                    country_risk=risk,
                )
            else:
                region = weighted(self.rng, REGIONS, region_weights)["region"]
                ethnic = weighted(self.rng, ETHNICITY, [int(e[region]) for e in ETHNICITY])[
                    "ethnic_group"
                ]
                first, middle, last = self.ghanaian_name(ethnic, sex, dob)
                person.update(
                    nationality="GHA",
                    first=first,
                    middle=middle,
                    last=last,
                    doc_type="GHANA_CARD",
                    doc=self.card(),
                    region=region,
                    country_risk="LOW",
                )
            self.add_profile(person)
            self.customers.append(person)
        for v in v1_customers:  # v1 customers join in the first month
            dob = dt.datetime.strptime(v["date_of_birth"], "%d-%b-%y").date()
            if dob.year > dt.date.today().year - 18:
                dob = dob.replace(year=dob.year - 100)
            person = {
                "month": 0,
                "sex": v["sex"].upper(),
                "dob": dob,
                "age": (self.start - dob).days // 365,
                "nationality": "GHA",
                "first": v["first_name"],
                "middle": None,
                "last": v["last_name"],
                "doc_type": "GHANA_CARD",
                "doc": v["ghana_card"],
                "country_risk": "LOW",
                "region": "Volta" if v["branch_id"] == "5" else "Greater Accra",
                "town": v["town"],
                "v1_occupation": v["occupation"],
                "v1_customer_id": v["customer_id"],
            }
            self.used_cards.add(v["ghana_card"])
            self.add_profile(person)
            self.customers.append(person)
        self.customers.sort(key=lambda p: (p["month"], p["doc"]))

    def add_profile(self, p):
        rng = self.rng
        age = p["age"]
        if "v1_occupation" in p:
            p["employment"], p["occupation"] = "EMPLOYED", p["v1_occupation"]
        else:
            if age < 25:
                p["employment"] = weighted(
                    rng, ["STUDENT", "EMPLOYED", "SELF_EMPLOYED", "UNEMPLOYED"], [35, 30, 20, 15]
                )
            elif age < 60:
                p["employment"] = weighted(
                    rng, ["EMPLOYED", "SELF_EMPLOYED", "UNEMPLOYED"], [42, 50, 8]
                )
            else:
                p["employment"] = weighted(
                    rng, ["RETIRED", "SELF_EMPLOYED", "EMPLOYED"], [60, 32, 8]
                )
            p["occupation"] = rng.choice(OCCUPATIONS[p["employment"]])
        bands = {
            "STUDENT": [70, 28, 2, 0, 0],
            "UNEMPLOYED": [80, 20, 0, 0, 0],
            "RETIRED": [35, 50, 12, 3, 0],
            "EMPLOYED": [10, 55, 22, 11, 2],
            "SELF_EMPLOYED": [20, 50, 18, 10, 2],
        }[p["employment"]]
        p["income"] = weighted(rng, list(INCOME), bands)
        p["volume"] = round(INCOME[p["income"]] * rng.uniform(0.6, 1.3), -1)
        p["funds"] = {
            "EMPLOYED": "SALARY",
            "SELF_EMPLOYED": "BUSINESS",
            "STUDENT": "GIFT",
            "RETIRED": "PENSION",
            "UNEMPLOYED": "GIFT",
        }[p["employment"]]
        p["purpose"] = {"EMPLOYED": "SALARY", "SELF_EMPLOYED": "BUSINESS"}.get(
            p["employment"], "SAVINGS"
        )
        p["employer"] = (
            rng.choice(EMPLOYERS)
            if p["employment"] == "EMPLOYED" and "v1_occupation" not in p
            else None
        )
        p.setdefault("town", rng.choice(TOWNS[p["region"]]))
        p["gps"] = self.digital_address(p["region"])
        p["phone"] = self.phone()
        p["email"] = self.email(p["first"], p["last"]) if rng.random() < 0.6 else None
        p["pep"] = rng.choice(PEP_ROLES) if rng.random() < 0.003 and age >= 35 else None
        roll = rng.random()  # what happened at onboarding
        p["kyc"] = (
            "DEFERRED"
            if roll < 0.03
            else "PENDING"
            if roll < 0.04
            else "SCREENING_HIT"
            if roll < 0.042
            else "VERIFIED"
        )
        p["risk"] = (
            "HIGH"
            if p["pep"]
            else weighted(
                rng,
                ["LOW", "MEDIUM", "HIGH"],
                {"LOW": [72, 24, 4], "MEDIUM": [40, 50, 10], "HIGH": [20, 50, 30]}[
                    p["country_risk"]
                ],
            )
        )
        p["nia_fix"] = rng.random() < 0.03  # NIA's spelling differs from what was typed
        p["product"] = (
            "GHS-CUR"
            if p["employment"] in ("EMPLOYED", "SELF_EMPLOYED") and rng.random() < 0.4
            else "GHS-STU"
            if p["employment"] == "STUDENT"
            else "GHS-SAV"
        )
        second = rng.random()
        p["second"] = (
            (
                "USD-SAV"
                if p["nationality"] != "GHA" or p["income"] in ("10K_50K", "OVER_50K")
                else "GHS-FD12"
            )
            if second < 0.18
            else None
        )
        p["photo"], p["signature"] = avatar(rng), signature(rng)
        p["kin"] = (
            self.rng.choice(CHRISTIAN[rng.choice(["MALE", "FEMALE"])]) + " " + p["last"],
            rng.choice(["SPOUSE", "PARENT", "SIBLING", "CHILD", "RELATIVE"]),
            self.phone(),
        )

    def build_employees(self):
        v1_jobs = {j["job_id"]: j for j in read_csv("v1_jobs.csv")}
        rng = self.rng
        for e in read_csv("v1_employees.csv"):
            hire = dt.datetime.strptime(
                e["hire_date"].replace("JUNE", "JUN").replace("JULY", "JUL"), "%d-%b-%y"
            ).date()
            branch = "HO-MAIN" if e["branch_id"] == "5" else "ACC-ELG"
            self.employees.append(
                {
                    "first": e["first_name"],
                    "last": e["last_name"],
                    "sex": e["sex"].upper(),
                    "job": v1_jobs[e["job_id"]]["job_title"],
                    "branch": branch,
                    "salary": e["salary"],
                    "hire": hire,
                    "email": self.email(e["first_name"], e["last_name"], "welbank.example.com"),
                }
            )
        jobs = {j["job_title"]: j for j in v1_jobs.values()}
        for code, _, region, _, _ in BRANCHES:
            for title, count in BRANCH_STAFF:
                have = sum(1 for e in self.employees if e["branch"] == code and e["job"] == title)
                for _ in range(max(0, count - have)):
                    sex = rng.choice(["MALE", "FEMALE"])
                    ethnic = weighted(rng, ETHNICITY, [int(x[region]) for x in ETHNICITY])[
                        "ethnic_group"
                    ]
                    dob = dt.date(rng.randint(1970, 2000), rng.randint(1, 12), rng.randint(1, 28))
                    first, _, last = self.ghanaian_name(ethnic, sex, dob)
                    lo, hi = float(jobs[title]["min_salary"]), float(jobs[title]["max_salary"])
                    self.employees.append(
                        {
                            "first": first,
                            "last": last,
                            "sex": sex,
                            "job": title,
                            "branch": code,
                            "salary": f"{round(rng.uniform(lo, hi), -2):.2f}",
                            "dob": dob,
                            "hire": dt.date(rng.randint(2012, 2024), rng.randint(1, 12), 1),
                            "email": self.email(first, last, "welbank.example.com"),
                        }
                    )
        for e in self.employees:
            e.setdefault("dob", e["hire"].replace(year=e["hire"].year - rng.randint(23, 35)))
            e["phone"] = self.phone()

    # ------------------------------------------------------------------ SQL
    def staff(self, branch, job):
        options = [e for e in self.employees if e["branch"] == branch and e["job"] == job]
        return self.rng.choice(options)["email"]

    def reference_sql(self, out):
        w = out.append
        w("-- Reference data (direct inserts: these tables have no package).")
        w(
            "INSERT INTO currencies (currency_code, currency_name, symbol, minor_units) VALUES ('GHS', 'Ghana cedi', UNISTR('GH\\20B5'), 2);"
        )  # GH₵, written in ASCII
        w(
            "INSERT INTO currencies (currency_code, currency_name, symbol, minor_units) VALUES ('USD', 'US dollar', '$', 2);"
        )
        w(
            "MERGE INTO countries c USING (SELECT 'GHA' code FROM dual) s ON (c.country_code = s.code) WHEN NOT MATCHED THEN"
            " INSERT (country_code, country_name, nationality_name, is_ecowas, risk_level) VALUES ('GHA', 'Ghana', 'Ghanaian', TRUE, 'LOW');"
        )
        w("UPDATE countries SET is_ecowas = TRUE WHERE country_code = 'GHA';")
        for code, (country, nationality, ecowas, risk, *_rest) in FOREIGN.items():
            w(
                f"INSERT INTO countries (country_code, country_name, nationality_name, is_ecowas, risk_level) VALUES "
                f"({q(code)}, {q(country)}, {q(nationality)}, {b(ecowas)}, {q(risk)});"
            )
        for r in REGIONS:
            w(f"INSERT INTO regions (region_name) VALUES ({q(r['region'])});")
        for code, name, region, street, town in BRANCHES:
            opened = (
                "DATE '2012-03-01'"
                if code in ("ACC-ELG", "HO-MAIN")
                else f"DATE '{self.rng.randint(2013, 2022)}-0{self.rng.randint(1, 9)}-01'"
            )
            w(
                f"INSERT INTO branches (branch_code, branch_name, region_id, phone, opened_on) VALUES ({q(code)}, {q(name)}, "
                f"(SELECT region_id FROM regions WHERE region_name = {q(region)}), {q(self.phone())}, {opened});"
            )
            w(
                f"INSERT INTO locations (branch_id, street_address, town, digital_address, landmark) VALUES ((SELECT branch_id FROM "
                f"branches WHERE branch_code = {q(code)}), {q(street)}, {q(town)}, {q(self.digital_address(region))}, "
                f"{q(self.rng.choice(LANDMARKS))});"
            )
        for dpt in read_csv("v1_departments.csv"):
            w(f"INSERT INTO departments (department_name) VALUES ({q(dpt['department_name'])});")
        departments = {
            x["department_id"]: x["department_name"] for x in read_csv("v1_departments.csv")
        }
        for j in read_csv("v1_jobs.csv"):
            w(
                f"INSERT INTO jobs (job_title, department_id, min_salary, max_salary) VALUES ({q(j['job_title'])}, (SELECT department_id "
                f"FROM departments WHERE department_name = {q(departments[j['department_id']])}), {j['min_salary']}, {j['max_salary']});"
            )
        limits = [
            ("Bank teller", "GHS", 20000),
            ("Bank teller", "USD", 2000),
            ("Teller supervisor", "GHS", 200000),
            ("Teller supervisor", "USD", 20000),
            ("Operations manager", "GHS", 500000),
            ("Branch manager", "GHS", 1000000),
            ("Branch manager", "USD", 100000),
        ]
        for job, cur, amount in limits:
            for kind in ("CASH_DEPOSIT", "CASH_WITHDRAWAL", "TRANSFER") + (
                ("REVERSAL",) if job != "Bank teller" else ()
            ):
                w(
                    f"INSERT INTO transaction_limits (job_id, txn_type, currency_code, max_amount) VALUES ((SELECT job_id FROM jobs "
                    f"WHERE job_title = {q(job)}), {q(kind)}, {q(cur)}, {amount});"
                )
        for job, amount in [("Credit analyst", 50000), ("Risk manager", 1000000)]:
            w(
                f"INSERT INTO transaction_limits (job_id, txn_type, currency_code, max_amount) VALUES ((SELECT job_id FROM jobs "
                f"WHERE job_title = {q(job)}), 'LOAN_DISBURSEMENT', 'GHS', {amount});"
            )
        w(
            "INSERT INTO account_products (product_code, product_name, account_type, currency_code, interest_rate, min_opening_balance, min_balance, monthly_fee) VALUES"
            " ('GHS-SAV', 'WEL Savings', 'SAVINGS', 'GHS', 5, 50, 20, 0);"
        )
        w(
            "INSERT INTO account_products (product_code, product_name, account_type, currency_code, interest_rate, min_opening_balance, min_balance, monthly_fee, overdraft_allowed) VALUES"
            " ('GHS-CUR', 'WEL Current', 'CURRENT', 'GHS', 0, 100, 0, 10, TRUE);"
        )
        w(
            "INSERT INTO account_products (product_code, product_name, account_type, currency_code, interest_rate) VALUES ('GHS-STU', 'WEL Student Saver', 'SAVINGS', 'GHS', 4);"
        )
        w(
            "INSERT INTO account_products (product_code, product_name, account_type, currency_code, interest_rate, min_opening_balance, term_months) VALUES"
            " ('GHS-FD12', 'WEL Fixed Deposit 12 months', 'FIXED_DEPOSIT', 'GHS', 18, 1000, 12);"
        )
        w(
            "INSERT INTO account_products (product_code, product_name, account_type, currency_code, interest_rate, min_opening_balance) VALUES ('USD-SAV', 'WEL Dollar Savings', 'SAVINGS', 'USD', 1, 100);"
        )
        w(
            "INSERT INTO loan_products (product_code, product_name, currency_code, interest_rate, min_amount, max_amount, max_term_months) VALUES ('GHS-PL', 'WEL Personal Loan', 'GHS', 26, 1000, 100000, 36);"
        )
        w(
            "INSERT INTO loan_products (product_code, product_name, currency_code, interest_rate, min_amount, max_amount, max_term_months) VALUES ('GHS-SME', 'WEL SME Loan', 'GHS', 28, 5000, 500000, 48);"
        )
        w(
            "-- Bank of Ghana loan classes. Day bands agree across sources; the provisioning rates are the commonly cited"
        )
        w(
            "-- schedule (OLEM was temporarily 5 % in 2020). Confirm against the current prudential directive."
        )
        for code, name, lo, hi, pct, npl in [
            ("CURRENT", "Current", 0, 29, 1, False),
            ("OLEM", "Other loans especially mentioned", 30, 89, 10, False),
            ("SUBSTANDARD", "Substandard", 90, 179, 25, True),
            ("DOUBTFUL", "Doubtful", 180, 359, 50, True),
            ("LOSS", "Loss", 360, 99999, 100, True),
        ]:
            w(
                f"MERGE INTO loan_classes c USING (SELECT {q(code)} code FROM dual) s ON (c.class_code = s.code) WHEN NOT MATCHED THEN INSERT "
                f"(class_code, class_name, min_days_past_due, max_days_past_due, provision_pct, is_non_performing) VALUES "
                f"({q(code)}, {q(name)}, {lo}, {hi}, {pct}, {b(npl)});"
            )
        for code, *_ in BRANCHES:
            for purpose, cur in [
                ("VAULT_CASH", "GHS"),
                ("VAULT_CASH", "USD"),
                ("FEE_INCOME", "GHS"),
                ("INTEREST_INCOME", "GHS"),
                ("INTEREST_EXPENSE", "GHS"),
                ("SUSPENSE", "GHS"),
            ]:
                w(
                    f"INSERT INTO accounts (account_class, internal_purpose, branch_id, currency_code, account_name, status, post_no_debit) VALUES "
                    f"('INTERNAL', {q(purpose)}, (SELECT branch_id FROM branches WHERE branch_code = {q(code)}), {q(cur)}, "
                    f"{q(purpose.replace('_', ' ').title() + ' ' + cur + ' ' + code)}, 'ACTIVE', FALSE);"
                )
        w(
            "INSERT INTO accounts (account_class, internal_purpose, branch_id, currency_code, account_name, status, post_no_debit) VALUES "
            "('INTERNAL', 'CAPITAL', (SELECT branch_id FROM branches WHERE branch_code = 'ACC-CEN'), 'GHS', 'Share capital', 'ACTIVE', FALSE);"
        )
        w("COMMIT;")
        w("-- Staff.")
        for e in self.employees:
            w(
                f"INSERT INTO employees (first_name, last_name, sex, date_of_birth, nationality, work_email, phone, job_id, branch_id, "
                f"salary, hire_date) VALUES ({q(e['first'])}, {q(e['last'])}, {q(e['sex'])}, {d(e['dob'])}, 'GHA', {q(e['email'])}, "
                f"{q(e['phone'])}, (SELECT job_id FROM jobs WHERE job_title = {q(e['job'])}), (SELECT branch_id FROM branches "
                f"WHERE branch_code = {q(e['branch'])}), {e['salary']}, {d(e['hire'])});"
            )
        w("-- Every branch employee reports to their branch manager.")
        w(
            "UPDATE employees e SET manager_id = (SELECT MIN(m.employee_id) FROM employees m JOIN jobs j ON j.job_id = m.job_id "
            "WHERE j.job_title = 'Branch manager' AND m.branch_id = e.branch_id AND m.employee_id <> e.employee_id);"
        )
        w("COMMIT;")

    def onboarding_sql(self, people, out):
        """One PL/SQL block onboarding a few customers through the packages."""
        w = out.append
        w("DECLARE")
        w(
            "  v_no VARCHAR2(12); v_acc VARCHAR2(13); v_acc2 VARCHAR2(13); v_n NUMBER; v_ref VARCHAR2(20);"
        )
        w("  PROCEDURE act_as(p_email VARCHAR2) IS")
        w("  BEGIN")
        w(
            "    UPDATE employees SET db_username = NULL WHERE db_username = SYS_CONTEXT('USERENV', 'SESSION_USER');"
        )
        w(
            "    UPDATE employees SET db_username = SYS_CONTEXT('USERENV', 'SESSION_USER') WHERE work_email = p_email;"
        )
        w("  END;")
        w("  FUNCTION region(p_name VARCHAR2) RETURN NUMBER IS v NUMBER;")
        w("  BEGIN SELECT region_id INTO v FROM regions WHERE region_name = p_name; RETURN v; END;")
        w("BEGIN")
        v1_accounts = {a["customer_id"]: a for a in read_csv("v1_accounts.csv")}
        for p in people:
            branch = (
                next(c for c, _, region, _, _ in BRANCHES if region == p["region"])
                if "v1_customer_id" not in p
                else ("HO-MAIN" if p["region"] == "Volta" else "ACC-ELG")
            )
            regional = [c for c, _, region, _, _ in BRANCHES if region == p["region"]]
            if "v1_customer_id" not in p and len(regional) > 1:
                branch = self.rng.choice(regional)
            p["branch"] = branch
            cso, manager, teller, supervisor = (
                self.staff(branch, "Customer service representative"),
                self.staff(branch, "Branch manager"),
                self.staff(branch, "Bank teller"),
                self.staff(branch, "Teller supervisor"),
            )
            w(
                f"  -- {p['first']} {p['last']} ({p['nationality']}, {p['region']}, onboarding month {p['month'] + 1})"
            )
            w(f"  act_as({q(cso)});")
            w("  v_no := pkg_customer.register_customer(")
            w(
                f"    p_first_name => {q(p['first'])}, p_last_name => {q(p['last'] + ('e' if p['nia_fix'] else ''))}, p_sex => {q(p['sex'])},"
            )
            w(
                f"    p_date_of_birth => {d(p['dob'])}, p_nationality => {q(p['nationality'])}, p_doc_type => {q(p['doc_type'])},"
            )
            w(
                f"    p_doc_number => {q(p['doc'])}, p_employment_status => {q(p['employment'])}, p_income_band => {q(p['income'])},"
            )
            w(
                f"    p_source_of_funds => {q(p['funds'])}, p_account_purpose => {q(p['purpose'])}, p_expected_monthly_volume => {p['volume']},"
            )
            w(
                f"    p_data_consent => TRUE, p_middle_name => {q(p['middle'])}, p_occupation => {q(p['occupation'])},"
            )
            w(
                f"    p_employer_name => {q(p['employer'])}, p_marketing_consent => {b(self.rng.random() < 0.4)},"
            )
            w(f"    p_is_pep => {b(p['pep'])}, p_pep_details => {q(p['pep'])});")
            w(
                f"  pkg_customer.add_address(v_no, 'RESIDENTIAL', {q('House ' + str(self.rng.randint(1, 250)) + ', ' + p['town'])}, {q(p['town'])}, "
                f"region({q(p['region'])}), 'GHA', {q(p['gps'])}, {q(self.rng.choice(LANDMARKS))}, {d(p['dob'] + dt.timedelta(days=365 * 18))}, "
                f"'UTILITY_BILL', {d(add_months(self.start, p['month']))});"
            )
            w(f"  pkg_customer.add_contact(v_no, 'MOBILE', {q(p['phone'])}, TRUE);")
            if p["email"]:
                w(f"  pkg_customer.add_contact(v_no, 'EMAIL', {q(p['email'])}, TRUE);")
            w(
                f"  pkg_customer.add_next_of_kin(v_no, {q(p['kin'][0])}, {q(p['kin'][1])}, {q(p['kin'][2])});"
            )
            w(
                f"  pkg_customer.add_file(v_no, 'PHOTO', 'image/png', {blob(p['photo'])}, {q(hashlib.sha256(p['photo']).hexdigest())});"
            )
            w(
                f"  pkg_customer.add_file(v_no, 'SIGNATURE', 'image/png', {blob(p['signature'])}, {q(hashlib.sha256(p['signature']).hexdigest())});"
            )
            if p["kyc"] == "PENDING":
                w(
                    "  v_acc := pkg_account.open_account(v_no, 'GHS-SAV');   -- waits: identity not verified yet"
                )
                continue
            if p["kyc"] == "DEFERRED":
                w(
                    "  v_n := pkg_customer.record_verification(v_no, 'ONBOARDING', 'FACE', 'NO_MATCH');"
                )
            else:
                nia = json.dumps(
                    {
                        "first_name": p["first"],
                        "last_name": p["last"],
                        "date_of_birth": f"{p['dob']:%Y-%m-%d}",
                        "sex": p["sex"],
                    }
                )  # NIA's spelling wins over what was typed
                w(
                    f"  v_n := pkg_customer.record_verification(v_no, 'ONBOARDING', {q(self.rng.choice(['FACE', 'FACE', 'SINGLE_FINGER']))}, "
                    f"'MATCH', {q('NIA-SIM-' + f'{self.rng.randint(0, 99999999):08d}')}, p_nia_data => {q(nia)});"
                )
            w(
                f"  pkg_customer.record_screening(v_no, {q('POTENTIAL_MATCH' if p['kyc'] == 'SCREENING_HIT' else 'CLEAR')});"
            )
            if p["kyc"] == "SCREENING_HIT":
                continue  # compliance is looking into it: nothing more yet
            if p["kyc"] == "VERIFIED":
                w("  pkg_customer.submit_kyc(v_no);")
            w(f"  v_acc := pkg_account.open_account(v_no, {q(p['product'])});")
            if p["second"]:
                w(f"  v_acc2 := pkg_account.open_account(v_no, {q(p['second'])});")
            w(f"  act_as({q(manager)});")
            if p["kyc"] == "VERIFIED":
                w(f"  pkg_customer.approve_kyc(v_no, {q(p['risk'])});")
            w("  pkg_account.approve_account(v_acc);")
            if p["second"]:
                w("  pkg_account.approve_account(v_acc2);")
            if "v1_customer_id" in p and p["v1_customer_id"] in v1_accounts:
                amount = v1_accounts[p["v1_customer_id"]]["balance"]
                w(f"  act_as({q(teller)});   -- balance carried over from the v1 database")
                w(
                    f"  v_ref := pkg_posting.cash_deposit(v_acc, {amount}, 'Opening balance from WEL Bank v1');"
                )
                w(
                    f"  IF pkg_posting.transaction_status(v_ref) = 'PENDING' THEN act_as({q(supervisor)}); pkg_posting.approve_transaction(v_ref); END IF;"
                )
        w("END;")
        w("/")

    def write(self):
        self.build_employees()
        self.build_people()
        out = [
            "-- Generated by database/seed/generate_seed.py: do not edit; edit the generator and run it again.",
            f"-- {len(self.customers)} customers, {len(self.employees)} employees, {self.months} months from {self.start}.",
            "WHENEVER SQLERROR EXIT SQL.SQLCODE",
            "SET SERVEROUTPUT ON SIZE UNLIMITED FEEDBACK OFF VERIFY OFF DEFINE ON LINESIZE 200",
            "ALTER SESSION SET CURRENT_SCHEMA = welbank;",
            f"@{SQL_DIR}/preflight.sql",
        ]
        self.reference_sql(out)
        out.append("PROMPT [seed] reference data and staff loaded")
        for month in range(self.months):
            first = add_months(self.start, month)
            last = add_months(first, 1) - dt.timedelta(days=1)
            people = [p for p in self.customers if p["month"] == month]
            for i in range(0, len(people), 8):
                self.onboarding_sql(people[i : i + 8], out)
            out.append("COMMIT;")
            out.append(
                f"PROMPT [seed] month {month + 1}/{self.months} ({first:%Y-%m}): {len(people)} customers onboarded"
            )
            out.append(
                f"@{SQL_DIR}/simulate_month.sql {month + 1} {first:%Y-%m-%d} {last:%Y-%m-%d}"
            )
        out.append(f"@{SQL_DIR}/finish.sql")
        BUILD.mkdir(exist_ok=True)
        (BUILD / "seed.sql").write_text("\n".join(out) + "\nEXIT\n", encoding="utf-8")
        size = (BUILD / "seed.sql").stat().st_size
        print(
            f"wrote {BUILD / 'seed.sql'}: {size / 1e6:.1f} MB, {len(self.customers)} customers, "
            f"{len(self.employees)} employees, {self.months} months from {self.start}"
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--customers",
        type=int,
        default=2000,
        help="number of customers, v1 ones included (default 2000)",
    )
    parser.add_argument(
        "--months", type=int, default=24, help="months of history to simulate (default 24)"
    )
    args = parser.parse_args()
    if args.customers < 100 or not 1 <= args.months <= 60:
        parser.error("--customers must be at least 100 and --months between 1 and 60")
    Generator(args.customers, args.months).write()


if __name__ == "__main__":
    main()
