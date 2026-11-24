package at.jaycloud.home.system.browser

import android.util.Log
import org.json.JSONObject
import java.io.File

/**
 * The browser's ad/tracker blocker on the device: loads the filter file
 * Dart compiled (lib/data/services/adblock_compiler.dart, format "HSAB 2")
 * and answers per request / per page. The matching is the same as
 * lib/data/services/adblock_matcher.dart (the tested reference) - change
 * both together.
 *
 * Plain hosts are kept as sorted 64-bit hashes (8 bytes each), site rules
 * and scriptlets as shared tables, so the ~90k hosts and ~27k URL patterns
 * of the default lists stay at about 10 MB.
 */
object AdblockEngine {
    private const val TAG = "AdblockEngine"

    // Resource types - the same bits as AdType in adblock_compiler.dart.
    const val SCRIPT = 1
    const val IMAGE = 2
    const val STYLESHEET = 4
    const val XHR = 8
    const val SUBDOCUMENT = 16
    const val MEDIA = 32
    const val FONT = 64
    const val OTHER = 128

    private class Rule(
        val kind: Char, // 'b' block, 'a' allow, 'i' important
        val pattern: String,
        val types: Int,
        val party: Int, // 0 any, 1 first party, 3 third party
        val domains: Array<String>,
    )

    private class Data(
        val blockHosts: LongArray,
        val allowHosts: HashSet<String>,
        val byToken: HashMap<String, ArrayList<Rule>>,
        val noToken: ArrayList<Rule>,
        val pageFlags: HashMap<String, String>,
        val genericKeyed: HashMap<String, Array<String>>,
        val genericHigh: Array<String>,
        val cssTable: Array<String>,
        val specific: HashMap<String, IntArray>,
        val cssExcept: HashMap<String, HashSet<String>>,
        val jsTable: Array<String>,
        val js: HashMap<String, IntArray>,
        val jsExcept: HashMap<String, HashSet<String>>,
    )

    @Volatile
    private var data: Data? = null

    @Volatile
    private var loadedFrom: String? = null

    @Volatile
    private var loadedStamp = 0L

    val loaded: Boolean get() = data != null

    /** Loads (or reloads, if the file changed) the compiled filters. Call off the main thread. */
    @Synchronized
    fun load(path: String): Boolean {
        val file = File(path)
        if (!file.exists()) {
            data = null
            loadedFrom = null
            return false
        }
        val stamp = file.lastModified() xor file.length()
        if (path == loadedFrom && stamp == loadedStamp && data != null) return true
        return try {
            val started = System.currentTimeMillis()
            data = parse(file)
            loadedFrom = path
            loadedStamp = stamp
            Log.i(TAG, "filters loaded in ${System.currentTimeMillis() - started} ms")
            true
        } catch (e: Exception) {
            Log.w(TAG, "can't load $path: $e")
            false
        }
    }

    fun unload() {
        data = null
        loadedFrom = null
    }

    private fun parse(file: File): Data {
        val blockHosts = ArrayList<Long>()
        val allowHosts = HashSet<String>()
        val byToken = HashMap<String, ArrayList<Rule>>()
        val noToken = ArrayList<Rule>()
        val pageFlags = HashMap<String, String>()
        val genericKeyed = HashMap<String, ArrayList<String>>()
        val genericHigh = ArrayList<String>()
        var cssTable = emptyArray<String>()
        val specific = HashMap<String, IntArray>()
        val cssExcept = HashMap<String, HashSet<String>>()
        var jsTable = emptyArray<String>()
        val js = HashMap<String, IntArray>()
        val jsExcept = HashMap<String, HashSet<String>>()
        val strings = HashMap<String, String>() // shares equal domain strings

        file.bufferedReader(Charsets.UTF_8, 1 shl 16).use { r ->
            if (r.readLine() != "HSAB 2") throw IllegalStateException("unknown format")
            while (true) {
                val head = r.readLine() ?: break
                if (head.isEmpty()) continue
                val space = head.indexOf(' ')
                val name = head.substring(1, space)
                val count = head.substring(space + 1).toInt()
                if (name == "csstable" || name == "jstable") {
                    val table = Array(count) { r.readLine() }
                    if (name == "csstable") cssTable = table else jsTable = table
                    continue
                }
                repeat(count) {
                    val line = r.readLine()
                    val tab = line.indexOf('\t')
                    val key = if (tab < 0) line else line.substring(0, tab)
                    val value = if (tab < 0) "" else line.substring(tab + 1)
                    when (name) {
                        "hosts" -> blockHosts.add(hash(line))
                        "allowhosts" -> allowHosts.add(line)
                        "net" -> {
                            val f = line.split('\t')
                            val rule = Rule(
                                kind = f[0][0],
                                pattern = f[2],
                                types = f[3].toInt(),
                                party = f[4].toInt(),
                                domains = if (f.size > 5 && f[5].isNotEmpty()) {
                                    f[5].split(',').map { d -> strings.getOrPut(d) { d } }.toTypedArray()
                                } else {
                                    emptyArray()
                                },
                            )
                            if (f[1].isEmpty()) noToken.add(rule) else byToken.getOrPut(f[1]) { ArrayList(2) }.add(rule)
                        }
                        "pageflags" -> pageFlags[key] = value
                        "generic" -> if (key.isEmpty()) genericHigh.add(value) else genericKeyed.getOrPut(key) { ArrayList(1) }.add(value)
                        "specific" -> specific[key] = indices(value)
                        "cssexcept" -> cssExcept.getOrPut(key) { HashSet() }.add(value)
                        "js" -> js[key] = indices(value)
                        "jsexcept" -> jsExcept.getOrPut(key) { HashSet() }.add(value)
                    }
                }
            }
        }
        val hosts = blockHosts.toLongArray().also { it.sort() }
        return Data(
            blockHosts = hosts,
            allowHosts = allowHosts,
            byToken = byToken,
            noToken = noToken,
            pageFlags = pageFlags,
            genericKeyed = HashMap<String, Array<String>>(genericKeyed.size * 2).also { m ->
                genericKeyed.forEach { (k, v) -> m[k] = v.toTypedArray() }
            },
            genericHigh = genericHigh.toTypedArray(),
            cssTable = cssTable,
            specific = specific,
            cssExcept = cssExcept,
            jsTable = jsTable,
            js = js,
            jsExcept = jsExcept,
        )
    }

    private fun indices(text: String): IntArray {
        if (text.isEmpty()) return IntArray(0)
        val parts = text.split(',')
        return IntArray(parts.size) { parts[it].toInt() }
    }

    /** 64-bit FNV-1a of the host's characters. */
    private fun hash(s: String): Long {
        var h = -0x340d631b7bdddcdbL // 0xcbf29ce484222325
        for (c in s) {
            h = h xor c.code.toLong()
            h *= 0x100000001b3L
        }
        return h
    }

    // --- hosts ---------------------------------------------------------------

    fun hostOf(url: String): String {
        val scheme = url.indexOf("://")
        if (scheme < 0) return ""
        val start = scheme + 3
        var end = start
        while (end < url.length) {
            val c = url[end]
            if (c == '/' || c == '?' || c == '#' || c == ':') break
            end++
        }
        val host = url.substring(start, end).lowercase()
        val at = host.lastIndexOf('@')
        return if (at < 0) host else host.substring(at + 1)
    }

    private val secondLevels = hashSetOf(
        "co", "com", "net", "org", "gov", "ac", "edu", "or", "gv", "ne", "go", "lg", "ltd", "plc", "sch", "nic",
        "mil", "gob", "nom",
    )

    private fun isIp(host: String) = host.contains(':') || host.all { it.isDigit() || it == '.' }

    fun registrableDomain(host: String): String {
        if (host.isEmpty() || isIp(host)) return host
        val labels = host.split('.')
        if (labels.size <= 2) return host
        val take = if (labels.last().length == 2 && labels[labels.size - 2] in secondLevels) 3 else 2
        return labels.subList(labels.size - take, labels.size).joinToString(".")
    }

    private fun hostCandidates(host: String): List<String> {
        val out = ArrayList<String>(4)
        var h = host
        while (h.isNotEmpty()) {
            out.add(h)
            val dot = h.indexOf('.')
            if (dot < 0) break
            h = h.substring(dot + 1)
        }
        return out
    }

    private fun entityKeys(host: String): List<String> {
        val labels = host.split('.')
        val n = labels.size
        val suffix = if (n >= 3 && labels[n - 1].length == 2 && labels[n - 2] in secondLevels) 2 else 1
        val out = ArrayList<String>()
        for (i in 0 until n - 1) {
            for (s in 1..suffix) {
                if (i > n - 1 - s) continue
                out.add(labels.subList(i, n - s).joinToString(".") + ".*")
            }
        }
        return out
    }

    private fun lookupKeys(host: String): List<String> = hostCandidates(host) + entityKeys(host)

    private fun domainCovers(domain: String, host: String): Boolean {
        if (host.isEmpty()) return false
        if (domain.endsWith(".*")) return entityKeys(host).contains(domain)
        return host == domain || host.endsWith(".$domain")
    }

    private fun pageFlags(d: Data, host: String): String {
        if (d.pageFlags.isEmpty() || host.isEmpty()) return ""
        val sb = StringBuilder()
        for (h in hostCandidates(host)) d.pageFlags[h]?.let { sb.append(it) }
        return sb.toString()
    }

    // --- network --------------------------------------------------------------

    /** The request's type from what WebView tells (no real type there): Accept and the file name. */
    fun requestType(url: String, accept: String?, range: Boolean): Int {
        val a = accept ?: ""
        if (a.startsWith("text/html")) return SUBDOCUMENT
        if (a.startsWith("image/")) return IMAGE
        if (a.startsWith("text/css")) return STYLESHEET
        var end = url.length
        val q = url.indexOf('?')
        if (q >= 0) end = q
        val h = url.indexOf('#')
        if (h in 0 until end) end = h
        val slash = url.lastIndexOf('/', end - 1)
        val dot = url.lastIndexOf('.', end - 1)
        val ext = if (dot > slash) url.substring(dot + 1, end).lowercase() else ""
        return when (ext) {
            "js", "mjs" -> SCRIPT
            "png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "avif", "bmp" -> IMAGE
            "css" -> STYLESHEET
            "woff", "woff2", "ttf", "otf", "eot" -> FONT
            "mp4", "webm", "m3u8", "mpd", "m4s", "mp3", "aac", "ogg", "m4a", "ts" -> MEDIA
            else -> if (range) MEDIA else (SCRIPT or XHR or OTHER)
        }
    }

    /**
     * Whether a sub-request for [url] (of [type] bits) on the page [pageHost]
     * is blocked. Main-frame navigations are never blocked (the caller
     * doesn't ask for them).
     */
    fun shouldBlock(url: String, pageHost: String, type: Int): Boolean {
        val d = data ?: return false
        val u = url.lowercase()
        val host = hostOf(u)
        if (host.isEmpty()) return false
        if (pageFlags(d, pageHost).contains('d')) return false
        val hostStart = u.indexOf(host, u.indexOf("://") + 3)
        val hostEnd = hostStart + host.length
        val third = pageHost.isEmpty() || registrableDomain(host) != registrableDomain(pageHost)
        val candidates = hostCandidates(host)

        var blocked = host != pageHost && candidates.any { java.util.Arrays.binarySearch(d.blockHosts, hash(it)) >= 0 }
        var important = false
        var allowed = d.allowHosts.isNotEmpty() && candidates.any { it in d.allowHosts }

        fun applies(r: Rule): Boolean {
            if (r.types and type == 0) return false
            if (r.party == 1 && third) return false
            if (r.party == 3 && !third) return false
            if (r.domains.isNotEmpty()) {
                var hasInclude = false
                var included = false
                for (dom in r.domains) {
                    if (dom.startsWith('~')) {
                        if (domainCovers(dom.substring(1), pageHost)) return false
                    } else {
                        hasInclude = true
                        if (!included && domainCovers(dom, pageHost)) included = true
                    }
                }
                if (hasInclude && !included) return false
            }
            return patternMatches(r.pattern, u, hostStart, hostEnd)
        }

        fun check(r: Rule) {
            when (r.kind) {
                'i' -> if (!important && applies(r)) important = true
                'b' -> if (!blocked && applies(r)) blocked = true
                'a' -> if (!allowed && applies(r)) allowed = true
            }
        }

        val seen = HashSet<String>()
        var start = -1
        for (i in 0..u.length) {
            val c = if (i < u.length) u[i] else ' '
            val word = c in 'a'..'z' || c in '0'..'9' || c == '%'
            if (word) {
                if (start < 0) start = i
            } else if (start >= 0) {
                val t = u.substring(start, i)
                start = -1
                if (!seen.add(t)) continue
                d.byToken[t]?.forEach(::check)
            }
        }
        d.noToken.forEach(::check)
        if (important) return true
        return blocked && !allowed
    }

    private fun isSeparator(c: Char): Boolean =
        !(c in 'a'..'z' || c in '0'..'9' || c in 'A'..'Z' || c == '_' || c == '-' || c == '.' || c == '%')

    private fun matchAt(seg: String, url: String, pos: Int): Int {
        var i = pos
        for (k in seg.indices) {
            val c = seg[k]
            if (c == '^') {
                if (i == url.length) {
                    for (r in k + 1 until seg.length) if (seg[r] != '^') return -1
                    return i
                }
                if (!isSeparator(url[i])) return -1
                i++
            } else {
                if (i >= url.length || url[i] != c) return -1
                i++
            }
        }
        return i
    }

    private fun rest(segs: List<String>, index: Int, url: String, pos: Int, endAnchor: Boolean): Boolean {
        var p = pos
        for (j in index until segs.size) {
            val seg = segs[j]
            if (j == segs.size - 1 && endAnchor) {
                for (s in p..url.length) if (matchAt(seg, url, s) == url.length) return true
                return false
            }
            var found = -1
            for (s in p..url.length) {
                val e = matchAt(seg, url, s)
                if (e >= 0) {
                    found = e
                    break
                }
            }
            if (found < 0) return false
            p = found
        }
        return !endAnchor || p == url.length
    }

    private fun patternMatches(pattern: String, url: String, hostStart: Int, hostEnd: Int): Boolean {
        var body = pattern
        var hostAnchor = false
        var startAnchor = false
        var endAnchor = false
        if (body.startsWith("||")) {
            hostAnchor = true
            body = body.substring(2)
        } else if (body.startsWith("|")) {
            startAnchor = true
            body = body.substring(1)
        }
        if (body.endsWith("|")) {
            endAnchor = true
            body = body.substring(0, body.length - 1)
        }
        val segs = body.split('*')
        if (hostAnchor || startAnchor) {
            val starts = ArrayList<Int>(4)
            if (startAnchor) {
                starts.add(0)
            } else {
                for (p in hostStart until hostEnd) if (p == hostStart || url[p - 1] == '.') starts.add(p)
            }
            for (s in starts) {
                if (segs.size == 1 && endAnchor) {
                    if (matchAt(segs[0], url, s) == url.length) return true
                    continue
                }
                val e = matchAt(segs[0], url, s)
                if (e < 0) continue
                if (segs.size == 1) return true
                if (rest(segs, 1, url, e, endAnchor)) return true
            }
            return false
        }
        return rest(segs, 0, url, 0, endAnchor)
    }

    // --- cosmetic & scriptlets -------------------------------------------------

    private fun cssExceptions(d: Data, keys: List<String>): Set<String> {
        if (d.cssExcept.isEmpty()) return emptySet()
        val out = HashSet<String>()
        for (k in keys) d.cssExcept[k]?.let { out.addAll(it) }
        return out
    }

    private fun appendRule(sb: StringBuilder, selector: String) {
        // One rule per selector: a selector this WebView doesn't know only
        // drops its own rule, not a whole list.
        sb.append(selector).append("{display:none!important}\n")
    }

    /**
     * What a page (frame) at [host] gets at its start, as JSON for
     * hs_page.js: {"css": hidden right away, "generic": whether to ask
     * [genericCss] for the page's classes/ids, "js": [[scriptlet, args...]]}.
     */
    fun pageConfig(host: String): String {
        val d = data ?: return "{\"css\":\"\",\"generic\":false,\"js\":[]}"
        val flags = pageFlags(d, host)
        if (flags.contains('d')) return "{\"css\":\"\",\"generic\":false,\"js\":[]}"
        val keys = if (host.isEmpty()) emptyList() else lookupKeys(host)
        val css = StringBuilder()
        val noCosmetic = flags.contains('e')
        val generic = !noCosmetic && !flags.contains('g')
        if (!noCosmetic) {
            val except = cssExceptions(d, keys)
            if (!flags.contains('s')) {
                val done = HashSet<Int>()
                for (k in keys) {
                    val idx = d.specific[k] ?: continue
                    for (i in idx) {
                        if (!done.add(i)) continue
                        val sel = d.cssTable[i]
                        if (sel !in except) appendRule(css, sel)
                    }
                }
            }
            if (generic) for (sel in d.genericHigh) if (sel !in except) appendRule(css, sel)
        }
        val js = StringBuilder("[")
        if (!noCosmetic && !flags.contains('s')) {
            val except = HashSet<String>()
            for (k in keys) d.jsExcept[k]?.let { except.addAll(it) }
            if ("" !in except) {
                val done = HashSet<Int>()
                for (k in keys + "*") {
                    val idx = d.js[k] ?: continue
                    for (i in idx) {
                        if (!done.add(i)) continue
                        val s = d.jsTable[i]
                        if (s in except) continue
                        if (js.length > 1) js.append(',')
                        js.append(s)
                    }
                }
            }
        }
        js.append(']')
        return "{\"css\":${JSONObject.quote(css.toString())},\"generic\":$generic,\"js\":$js}"
    }

    /** CSS hiding the generic selectors for [keys] ('.class', '#id') the page has. */
    fun genericCss(host: String, keys: List<String>): String {
        val d = data ?: return ""
        val except = if (host.isEmpty()) emptySet() else cssExceptions(d, lookupKeys(host))
        val sb = StringBuilder()
        for (k in keys) {
            val sels = d.genericKeyed[k] ?: continue
            for (sel in sels) if (sel !in except) appendRule(sb, sel)
        }
        return sb.toString()
    }
}
