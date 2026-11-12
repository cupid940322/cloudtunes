package com.gysbs.cloudtunes.core

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import java.time.Instant
import java.time.format.DateTimeFormatter
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer

/// ISO8601 日期（与 iOS JSONEncoder .iso8601 互通，无毫秒）
object ISODateSerializer : KSerializer<Instant> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("ISOInstant", PrimitiveKind.STRING)
    override fun deserialize(decoder: Decoder): Instant = Instant.parse(decoder.decodeString())
    override fun serialize(encoder: Encoder, value: Instant) {
        encoder.encodeString(DateTimeFormatter.ISO_INSTANT.format(value.truncatedTo(java.time.temporal.ChronoUnit.SECONDS)))
    }
}

val gistJson = Json {
    ignoreUnknownKeys = true
    isLenient = true
    explicitNulls = false
    encodeDefaults = true
}

/// 网盘类型。rawValue 必须与 iOS 端一致（中文），否则同步时对不上库
@Serializable
enum class CloudKind(val label: String) {
    @SerialName("光鸭云盘") GUANGYA("光鸭云盘"),
    @SerialName("百度网盘") BAIDU("百度网盘"),
    @SerialName("夸克网盘") QUARK("夸克网盘");
}

/// 云端文件/目录条目
@Serializable
data class CloudFile(
    val id: String,
    val name: String,
    val size: Long = 0,
    val isFolder: Boolean = false,
    @Serializable(with = ISODateSerializer::class) val modifiedAt: Instant? = null,
    val extra: Map<String, String> = emptyMap(),
)

/// 一首待播放的曲目（进播放队列用，字段与 iOS Track 对齐）
@Serializable
data class Track(
    val id: String,
    val file: CloudFile = CloudFile(id = "", name = ""),
    val providerKind: CloudKind = CloudKind.GUANGYA,
    val accountID: String = "",
    val titleOverride: String? = null,
    val artistOverride: String? = null,
    val album: String? = null,
    val artworkFile: String? = null,
    val duration: Double? = null,
    val neteaseID: Int? = null,
) {
    val title: String get() = titleOverride ?: Scanner.parse(file.name).title
    val artist: String? get() = artistOverride ?: Scanner.parse(file.name).artist
    val displayArtist: String get() = artist?.takeIf { it.isNotEmpty() } ?: "未知艺术家"
    val displayTitle: String get() = title.ifEmpty { file.name }
}

/// 歌词一行
data class LyricLine(val index: Int, val time: Double, val text: String)

/// 音乐库中的一首歌（持久化 + Gist 同步，字段名与 iOS LibraryTrack 完全一致）
@Serializable
data class LibraryTrack(
    val id: String,
    val fileID: String,
    val fileName: String,
    val size: Long = 0,
    val parentID: String = "",
    val title: String,
    val artist: String? = null,
    val album: String? = null,
    val duration: Double? = null,
    val artworkFile: String? = null,
    val scraped: Boolean = false,
    val neteaseID: Int? = null,
    @Serializable(with = ISODateSerializer::class) val addedAt: Instant? = null,
    val metaSource: String? = null,
    val confidence: Double? = null,
    val parentName: String? = null,
    val folderPath: List<String>? = null,
    val artworkURL: String? = null,
    @Serializable(with = ISODateSerializer::class) val updatedAt: Instant? = null,
) {
    val displayArtist: String get() = artist?.takeIf { it.isNotEmpty() } ?: "未知艺术家"
    val displayAlbum: String get() = album?.takeIf { it.isNotEmpty() } ?: "未知专辑"
    val albumKey: String?
        get() = album?.trim()?.takeIf { it.isNotEmpty() }?.let { "$it|${artist?.takeIf { a -> a.isNotEmpty() } ?: "群星"}" }
    val needsReview: Boolean get() = (confidence ?: 1.0) < 0.7

    fun toTrack(): Track = Track(
        id = id,
        file = CloudFile(id = fileID, name = fileName, size = size, isFolder = false, extra = mapOf("parentID" to parentID)),
        providerKind = CloudKind.entries.firstOrNull { id.startsWith("${it.label}-") } ?: CloudKind.GUANGYA,
        accountID = "",
        titleOverride = title,
        artistOverride = artist,
        album = album,
        artworkFile = artworkFile,
        duration = duration,
        neteaseID = neteaseID,
    )
}

/// 库的轻量描述（account.json 里用，不含曲目）
@Serializable
data class LibraryMeta(
    val id: String,
    val name: String,
    val providerKindRaw: String,
    val folderID: String,
    val folderName: String,
    val includeSubfolders: Boolean = true,
    @Serializable(with = ISODateSerializer::class) val createdAt: Instant,
    @Serializable(with = ISODateSerializer::class) val lastScanAt: Instant? = null,
    @Serializable(with = ISODateSerializer::class) val updatedAt: Instant,
)

/// 本地完整库（曲目存在一起）
@Serializable
data class MusicLibrary(
    val id: String,
    val name: String,
    val providerKindRaw: String,
    val folderID: String,
    val folderName: String,
    var tracks: List<LibraryTrack> = emptyList(),
    @Serializable(with = ISODateSerializer::class) val createdAt: Instant = Instant.now(),
    @Serializable(with = ISODateSerializer::class) val lastScanAt: Instant? = null,
    val includeSubfolders: Boolean? = true,
    @Serializable(with = ISODateSerializer::class) var updatedAt: Instant? = null,
) {
    val providerKind: CloudKind
        get() = CloudKind.entries.firstOrNull { it.label == providerKindRaw }
            ?: CloudKind.entries.firstOrNull { id.startsWith("${it.label}-") } ?: CloudKind.GUANGYA

    val artistCount: Int get() = tracks.mapNotNull { it.artist?.takeIf { a -> a.isNotEmpty() } }.toSet().size
    val albumCount: Int get() = tracks.mapNotNull { it.albumKey }.toSet().size
    val totalDuration: Double get() = tracks.sumOf { it.duration ?: 0.0 }
    val coverArtwork: String? get() = tracks.maxByOrNull { it.addedAt ?: Instant.EPOCH }?.artworkURL

    fun albums(): List<AlbumGroup> = tracks
        .groupBy { it.albumKey ?: "unknown-${it.id}" }
        .map { (key, list) ->
            AlbumGroup(
                id = key,
                name = list.first().displayAlbum,
                artist = list.firstNotNullOfOrNull { it.artist?.takeIf { a -> a.isNotEmpty() } },
                tracks = list,
            )
        }
        .sortedBy { it.name }

    fun artists(): List<ArtistGroup> = tracks
        .filter { !it.artist.isNullOrEmpty() }
        .groupBy { it.artist!! }
        .map { (name, list) -> ArtistGroup(id = name, name = name, tracks = list) }
        .sortedBy { it.name }
}

@Serializable
data class AlbumGroup(val id: String, val name: String, val artist: String?, val tracks: List<LibraryTrack>) {
    val artwork: String? get() = tracks.firstNotNullOfOrNull { it.artworkURL }
    val duration: Double get() = tracks.sumOf { it.duration ?: 0.0 }
}

@Serializable
data class ArtistGroup(val id: String, val name: String, val tracks: List<LibraryTrack>) {
    val artwork: String? get() = tracks.firstNotNullOfOrNull { it.artworkURL }
}

/// 播放队列快照（继续播放）
@Serializable
data class PlaybackSession(
    val tracks: List<Track> = emptyList(),
    val index: Int = 0,
    val position: Double = 0.0,
    @Serializable(with = ISODateSerializer::class) val updatedAt: Instant = Instant.now(),
)

/// Gist 里的 account.json（字段与 iOS SyncAccount 完全一致）
@Serializable
data class SyncAccount(
    val schemaVersion: Int = 1,
    @Serializable(with = ISODateSerializer::class) val updatedAt: Instant = Instant.now(),
    val deviceName: String = "",
    val libraries: List<LibraryMeta> = emptyList(),
    val favorites: List<String> = emptyList(),
    val recent: List<String> = emptyList(),
    val session: PlaybackSession? = null,
    @Serializable(with = ISODateMapSerializer::class) val deletedLibraries: Map<String, Instant> = emptyMap(),
    @Serializable(with = ISODateNestedMapSerializer::class) val deletedTracks: Map<String, Map<String, Instant>> = emptyMap(),
)

/// 库文件：library-<库ID>.json（字段与 iOS SyncLibraryFile 完全一致）
@Serializable
data class SyncLibraryFile(
    val libraryID: String,
    @Serializable(with = ISODateSerializer::class) val updatedAt: Instant = Instant.now(),
    val tracks: List<LibraryTrack> = emptyList(),
)

object ISODateMapSerializer : KSerializer<Map<String, Instant>> {
    private val inner = MapSerializer(String.serializer(), ISODateSerializer)
    override val descriptor: SerialDescriptor = inner.descriptor
    override fun deserialize(decoder: Decoder) = inner.deserialize(decoder)
    override fun serialize(encoder: Encoder, value: Map<String, Instant>) = inner.serialize(encoder, value)
}

object ISODateNestedMapSerializer : KSerializer<Map<String, Map<String, Instant>>> {
    private val inner = MapSerializer(String.serializer(), ISODateMapSerializer)
    override val descriptor: SerialDescriptor = inner.descriptor
    override fun deserialize(decoder: Decoder) = inner.deserialize(decoder)
    override fun serialize(encoder: Encoder, value: Map<String, Map<String, Instant>>) = inner.serialize(encoder, value)
}

/// 扫描进度
data class ScanProgress(
    var phase: String = "扫描目录…",
    var scannedFolders: Int = 0,
    var foundTracks: Int = 0,
    var scrapedTracks: Int = 0,
    var totalToScrape: Int = 0,
    var failed: Int = 0,
)
