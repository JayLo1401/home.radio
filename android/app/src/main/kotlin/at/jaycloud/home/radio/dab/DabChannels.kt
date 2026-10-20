package at.jaycloud.home.radio.dab

/** The DAB Band III channel plan (EN 50248 / ETSI EN 300 401 annex), 5A..13F. */
object DabChannels {
    data class Channel(val label: String, val freqKhz: Int)

    val BAND3 = listOf(
        Channel("5A", 174928), Channel("5B", 176640), Channel("5C", 178352), Channel("5D", 180064),
        Channel("6A", 181936), Channel("6B", 183648), Channel("6C", 185360), Channel("6D", 187072),
        Channel("7A", 188928), Channel("7B", 190640), Channel("7C", 192352), Channel("7D", 194064),
        Channel("8A", 195936), Channel("8B", 197648), Channel("8C", 199360), Channel("8D", 201072),
        Channel("9A", 202928), Channel("9B", 204640), Channel("9C", 206352), Channel("9D", 208064),
        Channel("10A", 209936), Channel("10N", 210096), Channel("10B", 211648), Channel("10C", 213360),
        Channel("10D", 215072), Channel("11A", 216928), Channel("11N", 217088), Channel("11B", 218640),
        Channel("11C", 220352), Channel("11D", 222064), Channel("12A", 223936), Channel("12N", 224096),
        Channel("12B", 225648), Channel("12C", 227360), Channel("12D", 229072), Channel("13A", 230784),
        Channel("13B", 232496), Channel("13C", 234208), Channel("13D", 235776), Channel("13E", 237488),
        Channel("13F", 239200),
    )
}
