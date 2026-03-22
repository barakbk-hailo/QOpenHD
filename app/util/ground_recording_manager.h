#ifndef GROUND_RECORDING_MANAGER_H
#define GROUND_RECORDING_MANAGER_H

#include <QObject>
#include <QProcess>
#include <QDateTime>
#include <QDir>
#include <QTimer>
#include <QThread>
#include <QStringList>

/**
 * Ground-side recording manager (v2 — raw stream tee approach).
 *
 * LIVE RECORDING (zero overhead):
 *   Tees the raw H.264 NALU stream from RTPReceiver to disk.
 *   Simultaneously saves Hailo detection metadata (JSONL sidecar).
 *   No re-encoding, no frame drops, no latency impact.
 *
 * OFFLINE BB EMBEDDING:
 *   Decodes the saved .h264, draws bounding boxes from the .jsonl
 *   sidecar onto decoded frames, re-encodes to *_BBs.mp4.
 *   Runs on a worker thread — can coexist with live display.
 *
 * Files per recording (in /home/pi/Videos/):
 *   ground_YYYYMMDD_HHMMSS.h264   — raw encoded stream
 *   ground_YYYYMMDD_HHMMSS.ts     — NALU timestamps (byte_offset elapsed_us is_keyframe nalu_size)
 *   ground_YYYYMMDD_HHMMSS.jsonl  — detection metadata per UDP packet
 *   ground_YYYYMMDD_HHMMSS.mp4    — muxed container (created on stop)
 *   ground_YYYYMMDD_HHMMSS_BBs.mp4 — with embedded bounding boxes (offline)
 *
 * Exposed to QML as "_groundRecordingManager".
 */
class GroundRecordingManager : public QObject
{
    Q_OBJECT

    Q_PROPERTY(bool isRecording READ isRecording NOTIFY isRecordingChanged)
    Q_PROPERTY(QString statusText READ statusText NOTIFY statusTextChanged)
    Q_PROPERTY(QString lastFileName READ lastFileName NOTIFY lastFileNameChanged)
    Q_PROPERTY(QString elapsedTime READ elapsedTime NOTIFY elapsedTimeChanged)
    Q_PROPERTY(int recordingCount READ recordingCount NOTIFY recordingCountChanged)
    Q_PROPERTY(bool isEmbedding READ isEmbedding NOTIFY isEmbeddingChanged)
    Q_PROPERTY(double embedProgress READ embedProgress NOTIFY embedProgressChanged)
    Q_PROPERTY(QString embedStatus READ embedStatus NOTIFY embedStatusChanged)
    Q_PROPERTY(bool includeLabels READ includeLabels WRITE setIncludeLabels NOTIFY includeLabelsChanged)
    Q_PROPERTY(QStringList videoList READ videoList NOTIFY videoListChanged)

public:
    explicit GroundRecordingManager(QObject *parent = nullptr);
    ~GroundRecordingManager();

    static GroundRecordingManager& instance();

    bool isRecording() const { return m_is_recording; }
    QString statusText() const { return m_status_text; }
    QString lastFileName() const { return m_last_file_name; }
    QString elapsedTime() const;
    int recordingCount() const;
    bool isEmbedding() const { return m_is_embedding; }
    double embedProgress() const { return m_embed_progress; }
    QString embedStatus() const { return m_embed_status; }
    bool includeLabels() const { return m_include_labels; }
    void setIncludeLabels(bool v);
    QStringList videoList() const;

    Q_INVOKABLE void startRecording();
    Q_INVOKABLE void stopRecording();
    Q_INVOKABLE void toggleRecording();
    Q_INVOKABLE QString recordingDirectory() const;
    Q_INVOKABLE void embedBBsForLast();
    Q_INVOKABLE void embedBBsForAll();
    Q_INVOKABLE void refreshVideoList();

signals:
    void isRecordingChanged();
    void statusTextChanged();
    void lastFileNameChanged();
    void elapsedTimeChanged();
    void recordingCountChanged();
    void isEmbeddingChanged();
    void embedProgressChanged();
    void embedStatusChanged();
    void includeLabelsChanged();
    void videoListChanged();

private slots:
    void onElapsedTimerTick();
    void onMuxFinished(int exitCode);

private:
    void setIsRecording(bool v);
    void setStatusText(const QString& text);
    void setIsEmbedding(bool v);
    void setEmbedProgress(double v);
    void setEmbedStatus(const QString& text);
    QString generateBaseName() const;
    void muxH264ToMp4(const QString& h264Path, const QString& mp4Path);
    void runEmbedJob(const QStringList& basePaths);

    QTimer *m_elapsed_timer = nullptr;
    bool m_is_recording = false;
    bool m_is_embedding = false;
    bool m_include_labels = true;
    double m_embed_progress = 0.0;
    QString m_status_text = "Idle";
    QString m_embed_status;
    QString m_last_file_name;
    QString m_recording_dir;
    QString m_current_base;  // base path without extension
    QDateTime m_recording_start_time;
    QProcess *m_mux_process = nullptr;
    QThread *m_embed_thread = nullptr;
};

#endif // GROUND_RECORDING_MANAGER_H
