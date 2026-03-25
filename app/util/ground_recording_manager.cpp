#include "ground_recording_manager.h"

#include <QDebug>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>
#include <QImage>
#include <QQuickItemGrabResult>

#include <cstdio>   // popen, pclose, fread, fwrite
#include <cstdlib>
#include <cmath>
#include <cstring>

#include "telemetry/models/hailodetectionmodel.h"
#include "telemetry/models/camerastreammodel.h"
#include "videostreaming/vscommon/rtp/rtpreceiver.h"

#ifdef QOPENHD_ENABLE_VIDEO_VIA_AVCODEC
extern "C" RTPReceiver* qopenhd_get_primary_rtp_receiver();
#else
static RTPReceiver* qopenhd_get_primary_rtp_receiver() { return nullptr; }
#endif

static const QString TAG = "GroundRec";

// ----------------------------------------------------------------
// Construction / singleton
// ----------------------------------------------------------------

GroundRecordingManager::GroundRecordingManager(QObject *parent)
    : QObject(parent)
{
    m_recording_dir = "/home/pi/Videos";
    QDir dir(m_recording_dir);
    if (!dir.exists()) dir.mkpath(".");

    m_elapsed_timer = new QTimer(this);
    m_elapsed_timer->setInterval(1000);
    connect(m_elapsed_timer, &QTimer::timeout, this, &GroundRecordingManager::onElapsedTimerTick);

    qDebug() << TAG << "Initialized, dir:" << m_recording_dir;
}

GroundRecordingManager::~GroundRecordingManager()
{
    if (m_is_recording) stopRecording();
}

GroundRecordingManager& GroundRecordingManager::instance()
{
    static GroundRecordingManager s;
    return s;
}

// ----------------------------------------------------------------
// Properties
// ----------------------------------------------------------------

QString GroundRecordingManager::elapsedTime() const
{
    if (!m_is_recording) return "00:00";
    const qint64 secs = m_recording_start_time.secsTo(QDateTime::currentDateTime());
    return QString("%1:%2")
        .arg(static_cast<int>(secs / 60), 2, 10, QChar('0'))
        .arg(static_cast<int>(secs % 60), 2, 10, QChar('0'));
}

int GroundRecordingManager::recordingCount() const
{
    QDir dir(m_recording_dir);
    return dir.entryList(QStringList() << "ground_*.mp4", QDir::Files).count();
}

QString GroundRecordingManager::recordingDirectory() const { return m_recording_dir; }

QStringList GroundRecordingManager::videoList() const
{
    QDir dir(m_recording_dir);
    QStringList all = dir.entryList(QStringList() << "ground_*.mp4", QDir::Files, QDir::Name);
    // Mark which ones have _BBs versions
    QStringList result;
    for (const auto& f : all) {
        if (f.contains("_BBs")) continue;  // skip _BBs files from the base list
        const QString base = f.left(f.size() - 4);  // remove .mp4
        const bool has_bbs = QFile::exists(m_recording_dir + "/" + base + "_BBs.mp4");
        result << (has_bbs ? (f + " [BBs]") : f);
    }
    return result;
}

void GroundRecordingManager::setSaveHud(bool v)
{
    if (m_save_hud != v) { m_save_hud = v; emit saveHudChanged(); }
}

void GroundRecordingManager::setIncludeDetections(bool v)
{
    if (m_include_detections != v) { m_include_detections = v; emit includeDetectionsChanged(); }
}

void GroundRecordingManager::setIncludeHud(bool v)
{
    if (m_include_hud != v) { m_include_hud = v; emit includeHudChanged(); }
}

void GroundRecordingManager::setOsdItem(QQuickItem* item)
{
    m_osd_item = item;
    qDebug() << TAG << "OSD item set:" << (item ? "ok" : "null");
}

// ----------------------------------------------------------------
// Live recording: start / stop
// ----------------------------------------------------------------

void GroundRecordingManager::startRecording()
{
    if (m_is_recording) return;

    const QString baseName = generateBaseName();
    m_current_base = m_recording_dir + "/" + baseName;
    const std::string h264 = (m_current_base + ".h264").toStdString();
    const std::string ts   = (m_current_base + ".ts").toStdString();
    const std::string jsonl= (m_current_base + ".jsonl").toStdString();

    qDebug() << TAG << "Starting recording:" << baseName;

    // Access the RTPReceiver through AVCodecDecoder (only available with avcodec video)
    RTPReceiver* rtp = qopenhd_get_primary_rtp_receiver();
    if (!rtp) {
        setStatusText("Error: no video stream (avcodec not available)");
        qDebug() << TAG << "No RTPReceiver available";
        return;
    }

    rtp->startRecordingStream(h264, ts);
    HailoDetectionModel::instance().startRecordingMetadata(jsonl);

    // --- OSD capture setup ---
    if (m_save_hud && m_osd_item) {
        int streamFps = CameraStreamModel::instance(0).get_stream_fps();
        if (streamFps <= 0) streamFps = 30;

        // Grab at the QML item's native display resolution (e.g. 2560x1440)
        // so text is rasterized at full quality.  During embed, we downscale
        // to video resolution with bilinear filtering — this gives supersampled
        // (SSAA) text that is much sharper than grabbing at 720p directly.
        m_osd_w = static_cast<int>(m_osd_item->width());
        m_osd_h = static_cast<int>(m_osd_item->height());
        if (m_osd_w <= 0 || m_osd_h <= 0) { m_osd_w = 1280; m_osd_h = 720; }
        m_osd_grab_pending = false;

        const std::string osdPath = (m_current_base + ".osd").toStdString();
        m_osd_file = fopen(osdPath.c_str(), "wb");
        if (m_osd_file) {
            // Write 24-byte header: magic, width, height, fps, tileSize, reserved
            uint32_t hdr[6] = {
                0x4F534433u,  // "OSD3" magic — RGBA tiles
                static_cast<uint32_t>(m_osd_w),
                static_cast<uint32_t>(m_osd_h),
                static_cast<uint32_t>(streamFps),
                static_cast<uint32_t>(OSD_TILE_SIZE),
                0
            };
            fwrite(hdr, sizeof(uint32_t), 6, m_osd_file);
            qDebug() << TAG << "OSD capture (sparse tiles):" << m_osd_w << "x" << m_osd_h
                     << "@" << streamFps << "fps, tile=" << OSD_TILE_SIZE;

            // Start grab timer at video FPS
            if (!m_osd_timer) {
                m_osd_timer = new QTimer(this);
                connect(m_osd_timer, &QTimer::timeout,
                        this, &GroundRecordingManager::onOsdGrabTimer);
            }
            m_osd_timer->setInterval(1000 / streamFps);
            m_osd_timer->start();
        } else {
            qDebug() << TAG << "Failed to open OSD file:" << osdPath.c_str();
        }
    }

    m_last_file_name = baseName + ".mp4";
    m_recording_start_time = QDateTime::currentDateTime();
    setIsRecording(true);
    setStatusText("Recording (raw tee)");
    m_elapsed_timer->start();
    emit lastFileNameChanged();
}

void GroundRecordingManager::stopRecording()
{
    if (!m_is_recording) return;

    qDebug() << TAG << "Stopping recording";

    RTPReceiver* rtp = qopenhd_get_primary_rtp_receiver();
    if (rtp) rtp->stopRecordingStream();
    HailoDetectionModel::instance().stopRecordingMetadata();

    // Stop OSD capture
    if (m_osd_timer) m_osd_timer->stop();
    {
        std::lock_guard<std::mutex> lock(m_osd_file_mutex);
        if (m_osd_file) { fclose(m_osd_file); m_osd_file = nullptr; }
    }

    m_elapsed_timer->stop();
    setIsRecording(false);
    setStatusText("Muxing to MP4...");

    // Mux .h264 → .mp4 (copy, no re-encode — near instant)
    muxH264ToMp4(m_current_base + ".h264", m_current_base + ".mp4");
}

void GroundRecordingManager::toggleRecording()
{
    if (m_is_recording) stopRecording(); else startRecording();
}

// ----------------------------------------------------------------
// Mux .h264 to .mp4 container
// ----------------------------------------------------------------

void GroundRecordingManager::muxH264ToMp4(const QString& h264Path, const QString& mp4Path)
{
    if (m_mux_process) { delete m_mux_process; m_mux_process = nullptr; }

    m_mux_process = new QProcess(this);
    connect(m_mux_process, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, [this](int code, QProcess::ExitStatus) { onMuxFinished(code); });

    QStringList args;
    args << "-y" << "-i" << h264Path
         << "-c" << "copy"
         << "-movflags" << "+faststart"
         << mp4Path;

    qDebug() << TAG << "Muxing:" << args.join(" ");
    m_mux_process->start("ffmpeg", args);
}

void GroundRecordingManager::onMuxFinished(int exitCode)
{
    qDebug() << TAG << "Mux finished, exit:" << exitCode;
    if (exitCode == 0) {
        setStatusText("Saved: " + m_last_file_name);
        // Remove raw .h264 now that .mp4 is safely muxed
        const QString h264Path = m_current_base + ".h264";
        if (QFile::exists(h264Path)) {
            QFile::remove(h264Path);
            qDebug() << TAG << "Removed raw .h264:" << h264Path;
        }
        // Also remove .ts timestamp log — only needed during mux
        const QString tsPath = m_current_base + ".ts";
        if (QFile::exists(tsPath)) {
            QFile::remove(tsPath);
        }
    } else {
        setStatusText("Mux error (exit " + QString::number(exitCode) + "), raw .h264 preserved");
    }
    emit recordingCountChanged();
    emit videoListChanged();
}

// ----------------------------------------------------------------
// Offline BB embedding
// ----------------------------------------------------------------

void GroundRecordingManager::embedBBsForLast()
{
    if (m_is_embedding || m_is_recording) return;
    if (m_current_base.isEmpty()) {
        setEmbedStatus("No recording available");
        return;
    }
    runEmbedJob(QStringList() << m_current_base);
}

void GroundRecordingManager::embedBBsForAll()
{
    if (m_is_embedding || m_is_recording) return;
    QDir dir(m_recording_dir);
    QStringList mp4s = dir.entryList(QStringList() << "ground_*.mp4", QDir::Files, QDir::Name);
    QStringList bases;
    for (const auto& f : mp4s) {
        if (f.contains("_BBs")) continue;
        const QString base = m_recording_dir + "/" + f.left(f.size() - 4);
        if (QFile::exists(base + "_BBs.mp4")) continue;  // already embedded
        if (!QFile::exists(base + ".jsonl")) continue;     // no metadata
        bases << base;
    }
    if (bases.isEmpty()) {
        setEmbedStatus("All videos already have BBs");
        return;
    }
    runEmbedJob(bases);
}

void GroundRecordingManager::runEmbedJob(const QStringList& basePaths)
{
    setIsEmbedding(true);
    setEmbedProgress(0.0);
    setEmbedStatus("Embedding BBs...");

    const bool detections = m_include_detections;
    const bool hud = m_include_hud;

    // Run on a worker thread to keep UI responsive.
    // IMPORTANT: we use POSIX popen/fread/fwrite here (not QProcess)
    // because QProcess needs a Qt event loop to flush its internal
    // write buffers, which a plain QThread::create lambda does not have.
    m_embed_thread = QThread::create([this, basePaths, detections, hud]() {
        const int total = basePaths.size();
        for (int i = 0; i < total; i++) {
            const QString base = basePaths[i];
            const QString mp4In = base + ".mp4";
            const QString jsonlIn = base + ".jsonl";
            const QString tsIn = base + ".ts";
            const QString mp4Out = base + "_BBs.mp4";

            QMetaObject::invokeMethod(this, [this, i, total, base]() {
                setEmbedProgress(static_cast<double>(i) / total);
                setEmbedStatus("Embedding: " + QFileInfo(base).fileName() + "...");
            }, Qt::QueuedConnection);

            // --- Probe video dimensions ---
            int vidW = 1920, vidH = 1080;
            double vidFps = 30.0;
            {
                // Use avg_frame_rate (not r_frame_rate) — r_frame_rate
                // comes from H.264 SPS timing and is often 60 for 30fps
                // streams (fields vs frames). avg_frame_rate is computed
                // from actual container timestamps and is accurate.
                QString probeCmd = QString(
                    "ffprobe -v error -select_streams v:0 "
                    "-show_entries stream=width,height,avg_frame_rate "
                    "-of csv=p=0 '%1'").arg(mp4In);
                FILE* probeP = popen(probeCmd.toUtf8().constData(), "r");
                if (probeP) {
                    char buf[256];
                    if (fgets(buf, sizeof(buf), probeP)) {
                        QStringList dims = QString(buf).trimmed().split(",");
                        if (dims.size() >= 2) {
                            vidW = dims[0].toInt();
                            vidH = dims[1].toInt();
                        }
                        if (dims.size() >= 3) {
                            QStringList fpsParts = dims[2].split("/");
                            if (fpsParts.size() == 2 && fpsParts[1].toDouble() > 0)
                                vidFps = fpsParts[0].toDouble() / fpsParts[1].toDouble();
                            else
                                vidFps = dims[2].toDouble();
                        }
                    }
                    pclose(probeP);
                }
                if (vidW <= 0) vidW = 1920;
                if (vidH <= 0) vidH = 1080;
                if (vidFps <= 0) vidFps = 30.0;
            }

            qDebug() << TAG << "Embed:" << mp4In << vidW << "x" << vidH << "@" << vidFps;

            // --- Read JSONL into memory ---
            QFile jsonlFile(jsonlIn);
            QVector<QPair<int64_t, QJsonArray>> bbFrames;
            if (detections && jsonlFile.open(QIODevice::ReadOnly)) {
                while (!jsonlFile.atEnd()) {
                    QByteArray line = jsonlFile.readLine().trimmed();
                    if (line.isEmpty()) continue;
                    QJsonDocument doc = QJsonDocument::fromJson(line);
                    if (!doc.isObject()) continue;
                    QJsonObject obj = doc.object();
                    int64_t ts = obj["ts_us"].toVariant().toLongLong();
                    QJsonArray dets = obj["dets"].toArray();
                    bbFrames.append({ts, dets});
                }
                jsonlFile.close();
            }

            // We don't use the .ts NALU timestamps for frame correlation
            // because .ts logs every NALU (SPS/PPS/slices), not just frames.
            // Instead we compute frame timestamps from frame index and FPS.
            (void)tsIn;

            // --- Load ALL OSD frames into memory (like BBs) ---
            // OSD is captured as sparse RGBA tiles at video resolution
            // at variable FPS, so we load upfront and timestamp-match.
            const QString osdIn = base + ".osd";
            uint32_t osdW = 0, osdH = 0;
            int osdTileSize = 0, osdTilesX = 0;
            struct OsdFrame {
                int64_t ts_us;
                std::vector<uint8_t> rgba;  // osdW * osdH * 4 (RGBA)
            };
            std::vector<OsdFrame> osdFrames;
            if (hud && QFile::exists(osdIn)) {
                FILE* osdFile = fopen(osdIn.toUtf8().constData(), "rb");
                if (osdFile) {
                    uint32_t hdr[6];
                    if (fread(hdr, sizeof(uint32_t), 6, osdFile) == 6
                        && hdr[0] == 0x4F534433u) {  // OSD3 = RGBA
                        osdW = hdr[1]; osdH = hdr[2];
                        osdTileSize = static_cast<int>(hdr[4]);
                        if (osdTileSize < 1) osdTileSize = 16;
                        osdTilesX = (osdW + osdTileSize - 1) / osdTileSize;
                        const size_t osdPixels = static_cast<size_t>(osdW) * osdH;
                        const size_t tileBytes = static_cast<size_t>(osdTileSize) * osdTileSize * 4;

                        while (true) {
                            uint64_t ts;
                            uint16_t numTiles;
                            if (fread(&ts, 8, 1, osdFile) != 1) break;
                            if (fread(&numTiles, 2, 1, osdFile) != 1) break;

                            OsdFrame frame;
                            frame.ts_us = static_cast<int64_t>(ts);
                            frame.rgba.resize(osdPixels * 4, 0);

                            std::vector<uint8_t> tileRGBA(tileBytes);
                            bool ok = true;
                            for (uint16_t t = 0; t < numTiles; t++) {
                                uint16_t tIdx;
                                if (fread(&tIdx, 2, 1, osdFile) != 1) { ok = false; break; }
                                if (fread(tileRGBA.data(), 1, tileBytes, osdFile) !=
                                    tileBytes) { ok = false; break; }
                                const int tx = tIdx % osdTilesX;
                                const int ty = tIdx / osdTilesX;
                                const int x0 = tx * osdTileSize;
                                const int y0 = ty * osdTileSize;
                                for (int dy = 0; dy < osdTileSize && (y0 + dy) < (int)osdH; dy++) {
                                    const int copyW = qMin(osdTileSize, static_cast<int>(osdW) - x0);
                                    if (copyW > 0)
                                        std::memcpy(&frame.rgba[((y0 + dy) * osdW + x0) * 4],
                                                    &tileRGBA[dy * osdTileSize * 4], copyW * 4);
                                }
                            }
                            if (!ok) break;
                            osdFrames.push_back(std::move(frame));
                        }
                        qDebug() << TAG << "OSD loaded (RGBA):" << osdFrames.size()
                                 << "frames," << osdW << "x" << osdH
                                 << "tile=" << osdTileSize;
                    }
                    fclose(osdFile);
                }
            }

            // --- Determine output resolution ---
            // When HUD overlay is enabled and OSD data exists, upscale to
            // 1080p so text stays legible. Otherwise output at native video res.
            int outW = vidW, outH = vidH;
            if (hud && !osdFrames.empty() && vidW < 1920) {
                outW = 1920;
                outH = 1080;
                qDebug() << TAG << "Output upscaled to FHD:" << outW << "x" << outH
                         << "(video:" << vidW << "x" << vidH << ")";
            } else {
                qDebug() << TAG << "Output at native res:" << outW << "x" << outH;
            }

            // --- Helper: find closest OSD frame for a given timestamp ---
            auto findClosestOsd = [&](int64_t frame_ts_us) -> int {
                if (osdFrames.empty()) return -1;
                int best = 0;
                int64_t bestDiff = std::abs(osdFrames[0].ts_us - frame_ts_us);
                for (size_t j = 1; j < osdFrames.size(); j++) {
                    int64_t diff = std::abs(osdFrames[j].ts_us - frame_ts_us);
                    if (diff < bestDiff) { bestDiff = diff; best = static_cast<int>(j); }
                    if (osdFrames[j].ts_us > frame_ts_us) break;
                }
                return best;
            };

            // --- Helper: find closest BB entry for a given timestamp ---
            auto findClosestBB = [&](int64_t frame_ts_us) -> QJsonArray {
                if (bbFrames.isEmpty()) return {};
                int best = 0;
                int64_t bestDiff = std::abs(bbFrames[0].first - frame_ts_us);
                for (int j = 1; j < bbFrames.size(); j++) {
                    int64_t diff = std::abs(bbFrames[j].first - frame_ts_us);
                    if (diff < bestDiff) { bestDiff = diff; best = j; }
                    if (bbFrames[j].first > frame_ts_us) break;
                }
                return bbFrames[best].second;
            };

            // --- Open decoder pipe (ffmpeg → raw RGB → our stdout) ---
            QString decCmd;
            if (outW != vidW || outH != vidH) {
                // Upscale via ffmpeg's Lanczos scaler
                decCmd = QString(
                    "ffmpeg -i '%1' -vf scale=%2:%3:flags=lanczos "
                    "-f rawvideo -pix_fmt rgb24 -v quiet - 2>/dev/null"
                ).arg(mp4In).arg(outW).arg(outH);
            } else {
                decCmd = QString(
                    "ffmpeg -i '%1' -f rawvideo -pix_fmt rgb24 -v quiet - 2>/dev/null"
                ).arg(mp4In);
            }
            FILE* decPipe = popen(decCmd.toUtf8().constData(), "r");
            if (!decPipe) {
                qDebug() << TAG << "Failed to start decoder pipe";
                continue;
            }

            // --- Open encoder pipe (our stdin → ffmpeg → mp4) ---
            QString encCmd = QString(
                "ffmpeg -f rawvideo -pix_fmt rgb24 -video_size %1x%2 "
                "-framerate %3 -i pipe:0 "
                "-pix_fmt yuv420p -c:v libx264 -preset fast -crf 20 "
                "-movflags +faststart -y '%4' 2>/tmp/embed_encode.log"
            ).arg(outW).arg(outH).arg(vidFps, 0, 'f', 2).arg(mp4Out);
            FILE* encPipe = popen(encCmd.toUtf8().constData(), "w");
            if (!encPipe) {
                qDebug() << TAG << "Failed to start encoder pipe";
                pclose(decPipe);
                continue;
            }

            const size_t frameSize = static_cast<size_t>(outW) * outH * 3;
            std::vector<uint8_t> frameBuf(frameSize);
            int frameIdx = 0;

            while (true) {
                // Read one full frame from decoder
                size_t totalRead = 0;
                while (totalRead < frameSize) {
                    size_t got = fread(frameBuf.data() + totalRead, 1,
                                       frameSize - totalRead, decPipe);
                    if (got == 0) break;  // EOF or error
                    totalRead += got;
                }
                if (totalRead < frameSize) break;  // EOF

                // Compute frame timestamp from index and FPS.
                const double frameDurUs = 1000000.0 / vidFps;
                int64_t frameTsUs = static_cast<int64_t>(frameIdx * frameDurUs);

                // --- Step 1: Draw bounding boxes (if enabled) ---
                if (detections && !bbFrames.isEmpty()) {
                    QJsonArray dets = findClosestBB(frameTsUs);

                    auto drawRect = [&](int x1, int y1, int x2, int y2,
                                        uint8_t r, uint8_t g, uint8_t b, int thick=2) {
                        uint8_t* data = frameBuf.data();
                        for (int t = 0; t < thick; t++) {
                            for (int x = qMax(0, x1); x < qMin(outW, x2); x++) {
                                int yt = qBound(0, y1 + t, outH - 1);
                                int yb = qBound(0, y2 - 1 - t, outH - 1);
                                data[(yt * outW + x) * 3 + 0] = r;
                                data[(yt * outW + x) * 3 + 1] = g;
                                data[(yt * outW + x) * 3 + 2] = b;
                                data[(yb * outW + x) * 3 + 0] = r;
                                data[(yb * outW + x) * 3 + 1] = g;
                                data[(yb * outW + x) * 3 + 2] = b;
                            }
                            for (int y = qMax(0, y1); y < qMin(outH, y2); y++) {
                                int xl = qBound(0, x1 + t, outW - 1);
                                int xr = qBound(0, x2 - 1 - t, outW - 1);
                                data[(y * outW + xl) * 3 + 0] = r;
                                data[(y * outW + xl) * 3 + 1] = g;
                                data[(y * outW + xl) * 3 + 2] = b;
                                data[(y * outW + xr) * 3 + 0] = r;
                                data[(y * outW + xr) * 3 + 1] = g;
                                data[(y * outW + xr) * 3 + 2] = b;
                            }
                        }
                    };

                    for (const auto& d : dets) {
                        QJsonObject det = d.toObject();
                        double cx = det["cx"].toDouble();
                        double cy = det["cy"].toDouble();
                        double w  = det["w"].toDouble();
                        double h  = det["h"].toDouble();
                        bool tracked = det["tracked"].toBool();
                        int x1 = static_cast<int>((cx - w/2) * outW);
                        int y1 = static_cast<int>((cy - h/2) * outH);
                        int x2 = static_cast<int>((cx + w/2) * outW);
                        int y2 = static_cast<int>((cy + h/2) * outH);
                        if (tracked)
                            drawRect(x1, y1, x2, y2, 0, 255, 0, 2);
                        else
                            drawRect(x1, y1, x2, y2, 255, 255, 255, 1);
                    }
                }

                // --- Step 2: Composite OSD RGBA overlay (if enabled) ---
                if (!osdFrames.empty() && osdW > 0 && osdH > 0) {
                    int osdIdx = findClosestOsd(frameTsUs);
                    if (osdIdx >= 0) {
                        const auto& osdRGBA = osdFrames[osdIdx].rgba;
                        uint8_t* data = frameBuf.data();

                        if (osdW == static_cast<uint32_t>(outW) &&
                            osdH == static_cast<uint32_t>(outH)) {
                            // Same resolution — direct 1:1 RGBA composite
                            const size_t maxPx = static_cast<size_t>(outW) * outH;
                            for (size_t p = 0; p < maxPx; p++) {
                                const uint8_t alpha = osdRGBA[p * 4 + 3];
                                if (alpha == 0) continue;
                                const size_t si = p * 4, di = p * 3;
                                if (alpha == 255) {
                                    data[di+0] = osdRGBA[si+0];
                                    data[di+1] = osdRGBA[si+1];
                                    data[di+2] = osdRGBA[si+2];
                                } else {
                                    const int a = alpha, ia = 255 - a;
                                    data[di+0] = static_cast<uint8_t>((data[di+0]*ia + osdRGBA[si+0]*a) / 255);
                                    data[di+1] = static_cast<uint8_t>((data[di+1]*ia + osdRGBA[si+1]*a) / 255);
                                    data[di+2] = static_cast<uint8_t>((data[di+2]*ia + osdRGBA[si+2]*a) / 255);
                                }
                            }
                        } else {
                            // OSD at different resolution — bilinear resample + blend
                            const double scaleX = static_cast<double>(osdW) / outW;
                            const double scaleY = static_cast<double>(osdH) / outH;
                            for (int y = 0; y < outH; y++) {
                                const double oy = y * scaleY;
                                const int oy0 = static_cast<int>(oy);
                                const int oy1 = qMin(oy0 + 1, static_cast<int>(osdH) - 1);
                                const double fy = oy - oy0;
                                const double ify = 1.0 - fy;
                                for (int x = 0; x < outW; x++) {
                                    const double ox = x * scaleX;
                                    const int ox0 = static_cast<int>(ox);
                                    const int ox1 = qMin(ox0 + 1, static_cast<int>(osdW) - 1);
                                    const double fx = ox - ox0;
                                    const double ifx = 1.0 - fx;
                                    // Bilinear sample all 4 RGBA channels
                                    const size_t i00 = (oy0 * osdW + ox0) * 4;
                                    const size_t i10 = (oy0 * osdW + ox1) * 4;
                                    const size_t i01 = (oy1 * osdW + ox0) * 4;
                                    const size_t i11 = (oy1 * osdW + ox1) * 4;
                                    const double w00 = ifx * ify, w10 = fx * ify;
                                    const double w01 = ifx * fy,  w11 = fx * fy;
                                    const int sr = static_cast<int>(osdRGBA[i00]*w00 + osdRGBA[i10]*w10 + osdRGBA[i01]*w01 + osdRGBA[i11]*w11 + 0.5);
                                    const int sg = static_cast<int>(osdRGBA[i00+1]*w00 + osdRGBA[i10+1]*w10 + osdRGBA[i01+1]*w01 + osdRGBA[i11+1]*w11 + 0.5);
                                    const int sb = static_cast<int>(osdRGBA[i00+2]*w00 + osdRGBA[i10+2]*w10 + osdRGBA[i01+2]*w01 + osdRGBA[i11+2]*w11 + 0.5);
                                    const int sa = static_cast<int>(osdRGBA[i00+3]*w00 + osdRGBA[i10+3]*w10 + osdRGBA[i01+3]*w01 + osdRGBA[i11+3]*w11 + 0.5);
                                    if (sa <= 0) continue;
                                    const size_t di = (y * outW + x) * 3;
                                    if (sa >= 255) {
                                        data[di+0] = static_cast<uint8_t>(qBound(0, sr, 255));
                                        data[di+1] = static_cast<uint8_t>(qBound(0, sg, 255));
                                        data[di+2] = static_cast<uint8_t>(qBound(0, sb, 255));
                                    } else {
                                        const int ia = 255 - sa;
                                        data[di+0] = static_cast<uint8_t>((data[di+0]*ia + qBound(0,sr,255)*sa) / 255);
                                        data[di+1] = static_cast<uint8_t>((data[di+1]*ia + qBound(0,sg,255)*sa) / 255);
                                        data[di+2] = static_cast<uint8_t>((data[di+2]*ia + qBound(0,sb,255)*sa) / 255);
                                    }
                                }
                            }
                        }
                    }
                }

                // Write frame to encoder
                size_t written = fwrite(frameBuf.data(), 1, frameSize, encPipe);
                if (written < frameSize) {
                    qDebug() << TAG << "Encoder pipe broke at frame" << frameIdx;
                    break;
                }
                frameIdx++;

                if (frameIdx % 30 == 0) {
                    QMetaObject::invokeMethod(this, [this, i, total, frameIdx]() {
                        setEmbedProgress((static_cast<double>(i) + 0.5) / total);
                        setEmbedStatus(QString("Frame %1...").arg(frameIdx));
                    }, Qt::QueuedConnection);
                }
            }

            // Close pipes — pclose() waits for the child to finish
            int encRet = pclose(encPipe);
            int decRet = pclose(decPipe);

            qDebug() << TAG << "Embed done:" << mp4Out
                     << "frames:" << frameIdx
                     << "enc_exit:" << WEXITSTATUS(encRet)
                     << "dec_exit:" << WEXITSTATUS(decRet);
        }

        QMetaObject::invokeMethod(this, [this]() {
            setIsEmbedding(false);
            setEmbedProgress(1.0);
            setEmbedStatus("Done");
            emit videoListChanged();
        }, Qt::QueuedConnection);
    });

    m_embed_thread->start();
}

void GroundRecordingManager::onOsdGrabTimer()
{
    if (!m_osd_item || !m_osd_file) return;
    if (m_osd_grab_pending) return;  // previous grab still in flight

    const QSize grabSize(m_osd_w, m_osd_h);
    auto result = m_osd_item->grabToImage(grabSize);
    if (!result) return;

    m_osd_grab_pending = true;

    // Capture the timestamp now (before async grab completes)
    const int64_t ts_us = m_recording_start_time.msecsTo(QDateTime::currentDateTime()) * 1000LL;

    connect(result.data(), &QQuickItemGrabResult::ready, this,
        [this, result, ts_us]() {
            m_osd_grab_pending = false;
            QImage img = result->image();
            if (img.isNull()) return;

            // Convert to ARGB32 if needed
            if (img.format() != QImage::Format_ARGB32 &&
                img.format() != QImage::Format_ARGB32_Premultiplied) {
                img = img.convertToFormat(QImage::Format_ARGB32);
            }

            const int w = img.width();
            const int h = img.height();
            const int T = OSD_TILE_SIZE;
            const int tilesX = (w + T - 1) / T;
            const int tilesY = (h + T - 1) / T;

            // --- Pass 1: find which tiles have any non-transparent pixel ---
            std::vector<uint16_t> activeIndices;
            activeIndices.reserve(256);  // typical HUD covers ~200 tiles

            for (int ty = 0; ty < tilesY; ty++) {
                for (int tx = 0; tx < tilesX; tx++) {
                    const int x0 = tx * T;
                    const int y0 = ty * T;
                    const int x1 = qMin(x0 + T, w);
                    const int y1 = qMin(y0 + T, h);
                    bool hasContent = false;
                    for (int y = y0; y < y1 && !hasContent; y++) {
                        const QRgb* row = reinterpret_cast<const QRgb*>(img.constScanLine(y));
                        for (int x = x0; x < x1; x++) {
                            if (qAlpha(row[x]) > 0) { hasContent = true; break; }
                        }
                    }
                    if (hasContent) {
                        activeIndices.push_back(static_cast<uint16_t>(ty * tilesX + tx));
                    }
                }
            }

            // --- Write sparse frame to file ---
            std::lock_guard<std::mutex> lock(m_osd_file_mutex);
            if (!m_osd_file) return;

            uint64_t ts = static_cast<uint64_t>(ts_us);
            fwrite(&ts, sizeof(ts), 1, m_osd_file);
            uint16_t numTiles = static_cast<uint16_t>(activeIndices.size());
            fwrite(&numTiles, sizeof(numTiles), 1, m_osd_file);

            // --- Pass 2: write RGBA data for each active tile ---
            uint8_t tileRGBA[T * T * 4];
            for (uint16_t idx : activeIndices) {
                fwrite(&idx, sizeof(idx), 1, m_osd_file);

                const int tx = idx % tilesX;
                const int ty_val = idx / tilesX;
                const int x0 = tx * T;
                const int y0 = ty_val * T;
                const int x1 = qMin(x0 + T, w);
                const int y1 = qMin(y0 + T, h);

                std::memset(tileRGBA, 0, T * T * 4);
                const bool premul = (img.format() == QImage::Format_ARGB32_Premultiplied);
                for (int y = y0; y < y1; y++) {
                    const QRgb* row = reinterpret_cast<const QRgb*>(img.constScanLine(y));
                    for (int x = x0; x < x1; x++) {
                        const QRgb px = row[x];
                        const int off = ((y - y0) * T + (x - x0)) * 4;
                        const uint8_t a = static_cast<uint8_t>(qAlpha(px));
                        if (a == 0) continue;
                        if (premul && a < 255) {
                            // Un-premultiply
                            tileRGBA[off + 0] = static_cast<uint8_t>(qMin(255, qRed(px) * 255 / a));
                            tileRGBA[off + 1] = static_cast<uint8_t>(qMin(255, qGreen(px) * 255 / a));
                            tileRGBA[off + 2] = static_cast<uint8_t>(qMin(255, qBlue(px) * 255 / a));
                        } else {
                            tileRGBA[off + 0] = static_cast<uint8_t>(qRed(px));
                            tileRGBA[off + 1] = static_cast<uint8_t>(qGreen(px));
                            tileRGBA[off + 2] = static_cast<uint8_t>(qBlue(px));
                        }
                        tileRGBA[off + 3] = a;
                    }
                }
                fwrite(tileRGBA, 1, T * T * 4, m_osd_file);
            }
        });
}

void GroundRecordingManager::refreshVideoList()
{
    emit videoListChanged();
}

// ----------------------------------------------------------------
// Helpers
// ----------------------------------------------------------------

void GroundRecordingManager::onElapsedTimerTick() { emit elapsedTimeChanged(); }

void GroundRecordingManager::setIsRecording(bool v)
{
    if (m_is_recording != v) { m_is_recording = v; emit isRecordingChanged(); }
}

void GroundRecordingManager::setStatusText(const QString& t)
{
    if (m_status_text != t) { m_status_text = t; emit statusTextChanged(); }
}

void GroundRecordingManager::setIsEmbedding(bool v)
{
    if (m_is_embedding != v) { m_is_embedding = v; emit isEmbeddingChanged(); }
}

void GroundRecordingManager::setEmbedProgress(double v)
{
    m_embed_progress = v; emit embedProgressChanged();
}

void GroundRecordingManager::setEmbedStatus(const QString& t)
{
    if (m_embed_status != t) { m_embed_status = t; emit embedStatusChanged(); }
}

QString GroundRecordingManager::generateBaseName() const
{
    return QString("ground_%1")
        .arg(QDateTime::currentDateTime().toString("yyyyMMdd_HHmmss"));
}
