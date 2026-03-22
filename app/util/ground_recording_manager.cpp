#include "ground_recording_manager.h"

#include <QDebug>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>

#include <cstdio>   // popen, pclose, fread, fwrite
#include <cstdlib>
#include <cmath>

#include "telemetry/models/hailodetectionmodel.h"
#include "videostreaming/avcodec/avcodec_decoder.h"

extern "C" RTPReceiver* qopenhd_get_primary_rtp_receiver();

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

void GroundRecordingManager::setIncludeLabels(bool v)
{
    if (m_include_labels != v) { m_include_labels = v; emit includeLabelsChanged(); }
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

    // Access the RTPReceiver through AVCodecDecoder
    RTPReceiver* rtp = qopenhd_get_primary_rtp_receiver();
    if (!rtp) {
        setStatusText("Error: no video stream");
        qDebug() << TAG << "No RTPReceiver available";
        return;
    }

    rtp->startRecordingStream(h264, ts);
    HailoDetectionModel::instance().startRecordingMetadata(jsonl);

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

    const bool labels = m_include_labels;

    // Run on a worker thread to keep UI responsive.
    // IMPORTANT: we use POSIX popen/fread/fwrite here (not QProcess)
    // because QProcess needs a Qt event loop to flush its internal
    // write buffers, which a plain QThread::create lambda does not have.
    m_embed_thread = QThread::create([this, basePaths, labels]() {
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
            if (jsonlFile.open(QIODevice::ReadOnly)) {
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
            QString decCmd = QString(
                "ffmpeg -i '%1' -f rawvideo -pix_fmt rgb24 -v quiet - 2>/dev/null"
            ).arg(mp4In);
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
            ).arg(vidW).arg(vidH).arg(vidFps, 0, 'f', 2).arg(mp4Out);
            FILE* encPipe = popen(encCmd.toUtf8().constData(), "w");
            if (!encPipe) {
                qDebug() << TAG << "Failed to start encoder pipe";
                pclose(decPipe);
                continue;
            }

            const size_t frameSize = static_cast<size_t>(vidW) * vidH * 3;
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
                // This is more reliable than NALU timestamps because the
                // .ts sidecar logs every NALU (including SPS/PPS) not just
                // frames, while the decoder emits frames sequentially.
                const double frameDurUs = 1000000.0 / vidFps;
                int64_t frameTsUs = static_cast<int64_t>(frameIdx * frameDurUs);

                // Find & draw bounding boxes
                QJsonArray dets = findClosestBB(frameTsUs);

                auto drawRect = [&](int x1, int y1, int x2, int y2,
                                    uint8_t r, uint8_t g, uint8_t b, int thick=2) {
                    uint8_t* data = frameBuf.data();
                    for (int t = 0; t < thick; t++) {
                        for (int x = qMax(0, x1); x < qMin(vidW, x2); x++) {
                            int yt = qBound(0, y1 + t, vidH - 1);
                            int yb = qBound(0, y2 - 1 - t, vidH - 1);
                            data[(yt * vidW + x) * 3 + 0] = r;
                            data[(yt * vidW + x) * 3 + 1] = g;
                            data[(yt * vidW + x) * 3 + 2] = b;
                            data[(yb * vidW + x) * 3 + 0] = r;
                            data[(yb * vidW + x) * 3 + 1] = g;
                            data[(yb * vidW + x) * 3 + 2] = b;
                        }
                        for (int y = qMax(0, y1); y < qMin(vidH, y2); y++) {
                            int xl = qBound(0, x1 + t, vidW - 1);
                            int xr = qBound(0, x2 - 1 - t, vidW - 1);
                            data[(y * vidW + xl) * 3 + 0] = r;
                            data[(y * vidW + xl) * 3 + 1] = g;
                            data[(y * vidW + xl) * 3 + 2] = b;
                            data[(y * vidW + xr) * 3 + 0] = r;
                            data[(y * vidW + xr) * 3 + 1] = g;
                            data[(y * vidW + xr) * 3 + 2] = b;
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
                    int x1 = static_cast<int>((cx - w/2) * vidW);
                    int y1 = static_cast<int>((cy - h/2) * vidH);
                    int x2 = static_cast<int>((cx + w/2) * vidW);
                    int y2 = static_cast<int>((cy + h/2) * vidH);
                    if (tracked)
                        drawRect(x1, y1, x2, y2, 0, 255, 0, 2);
                    else
                        drawRect(x1, y1, x2, y2, 255, 255, 255, 1);

                    if (labels) {
                        int lw = 40, lh = 16;
                        int lx = qBound(0, x1, vidW - lw);
                        int ly = qBound(0, y1 - lh, vidH - lh);
                        uint8_t* data = frameBuf.data();
                        for (int py = ly; py < ly + lh && py < vidH; py++) {
                            for (int px = lx; px < lx + lw && px < vidW; px++) {
                                data[(py * vidW + px) * 3 + 0] = tracked ? 0 : 80;
                                data[(py * vidW + px) * 3 + 1] = tracked ? 180 : 80;
                                data[(py * vidW + px) * 3 + 2] = tracked ? 0 : 80;
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
