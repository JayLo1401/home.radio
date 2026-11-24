# Home Media: JLayer loads its tables (sfd.ser, ...) relative to its own
# package - renamed by R8 they aren't found ("unable to load resource").
-keep class javazoom.jl.decoder.** { *; }
