# Chooses one name per feature per language and writes it as nde:preferredName.
#
# Consumers need a single label per language, and GeoNames does not provide one: isPreferredName
# means 'is an official name', with no uniqueness constraint, so 25 features carry several Dutch
# official names and 8,266 several English ones. Deriving the choice in a client query is what made
# the Network of Terms searches unplannable – picking one name requires a negation or an aggregate
# over every name a feature has, and Jena materialises both – so it is settled here instead, once
# per build, where the rows are already in hand.
#
# The predicate is NDE's, not GeoNames'. skos:prefLabel would be wrong twice over: the ontology
# already makes gn:officialName a subproperty of it, and promoting a plain gn:alternateName – the
# only Dutch name 76,511 features have – would assert the same literal as both a skos:prefLabel and
# (through gn:alternateName) a skos:altLabel, which SKOS integrity condition S13 forbids.
#
# Input: the alternate names chunks, headers stripped, sorted by geonameid then isolanguage.
# Columns: 1 alternateNameId, 2 geonameid, 3 isolanguage, 4 name, 5 isPreferredName, 6 isShortName,
# 7 isColloquial, 8 isHistoric.
BEGIN { FS = "\t"; OFS = "" }

# Only ISO 639 codes: the column doubles as a slot for 'wkdt', 'post', 'link' and friends, and for
# variants like zh-Hant that the mapping drops as well.
$3 !~ /^[a-z][a-z][a-z]?$/ { next }

# An obsolete or slang name must never become the label a client displays, which is the same reason
# the mapping tests these two flags before isPreferredName.
$7 != "" || $8 != "" { next }

# GeoNames ships rows whose name is empty – 2967681 carries one tagged 'si'. The mapping drops them
# without a rule for it, because fx:null-string "" leaves ?name unbound and the CONSTRUCT then emits
# nothing. awk has no such notion, so the skip is explicit here; without it a feature prefers an
# empty literal over its real name.
$4 == "" { next }

{
    key = $2 SUBSEP $3
    # isPreferredName says the name is official; isShortName says it is the short form of one. The
    # pair is what separates a feature's several official names: of the 8,266 features with more
    # than one English official name, 8,264 have exactly one of them flagged short.
    score = ($5 != "" ? 2 : 0) + ($6 != "" ? 1 : 0)
    if (key != current) {
        if (current != "") emit()
        current = key; id = $1; lang = $3; name = $4; best = score
    } else if (score > best || (score == best && length($4) < length(name)) \
               || (score == best && length($4) == length(name) && $1 + 0 < id + 0)) {
        # Shortest wins a tie – GeoNames offers nothing else to separate 'Noord-Korea' from 'Korea,
        # Democratische Volksrepubliek', and the common form is the one a client wants to show. The
        # alternateNameId only breaks a tie between names of equal length, so a run is reproducible.
        id = $1; name = $4; best = score
    }
}

END { if (current != "") emit() }

function emit(   escaped) {
    escaped = name
    gsub(/\\/, "\\\\", escaped)
    gsub(/"/, "\\\"", escaped)
    gsub(/\t/, "\\t", escaped)
    gsub(/\r/, "\\r", escaped)
    gsub(/\n/, "\\n", escaped)
    split(current, parts, SUBSEP)
    print "<https://sws.geonames.org/", parts[1], "/> <https://def.nde.nl/geonames#preferredName> \"", escaped, "\"@", lang, " ."
}
