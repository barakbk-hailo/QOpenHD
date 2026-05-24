#include "hailodetectionmodel.h"

#include <QDebug>

#include "../../videostreaming/vscommon/udp/UDPReceiver.h"
#include "tutil/qopenhdmavlinkhelper.hpp"

static uint16_t read_u16_le(const uint8_t* p) {
    return static_cast<uint16_t>(p[0]) | (static_cast<uint16_t>(p[1]) << 8);
}

HailoDetectionModel::HailoDetectionModel(QObject* parent)
    : QObject(parent)
{
    m_receiving_timer = std::make_unique<QTimer>(this);
    QObject::connect(m_receiving_timer.get(), &QTimer::timeout,
                     this, &HailoDetectionModel::update_receiving);
    m_receiving_timer->start(1000);
}

HailoDetectionModel::~HailoDetectionModel()
{
    if (m_udp_receiver) {
        m_udp_receiver->stopReceiving();
    }
}

HailoDetectionModel& HailoDetectionModel::instance()
{
    static HailoDetectionModel inst{};
    return inst;
}

void HailoDetectionModel::startReceiving()
{
    UDPReceiver::Configuration config;
    config.udp_ip_address = "127.0.0.1";
    config.udp_port = 5520;
    m_udp_receiver = std::make_unique<UDPReceiver>(
        "hailo_det", config,
        [this](const uint8_t data[], size_t len) {
            on_udp_data(data, len);
        });
    m_udp_receiver->startReceiving();
    qDebug() << "HailoDetectionModel: listening on UDP 5520";
}

void HailoDetectionModel::on_udp_data(const uint8_t* data, size_t len)
{
    // v3 header: version(1) + active_id(2) + follow_id(2) + count(1)      = 6 bytes
    // v4 header: version(1) + active_id(2) + follow_id(2) + mode(1) + count(1) = 7 bytes
    // Per bbox (both versions): id(2) + cx(2) + cy(2) + w(2) + h(2) + flags(1) = 11 bytes
    if (len < 6) return;

    const uint8_t version = data[0];
    if (version < 3) return;  // only v3+ supported

    m_last_data_ms = QOpenHDMavlinkHelper::getTimeMilliseconds();

    const uint16_t active = read_u16_le(data + 1);
    const int16_t  follow = static_cast<int16_t>(read_u16_le(data + 3));

    // Mode is only present from v4 onwards. v3 senders default to AUTO
    // (the only state the air side could communicate before mode landed).
    uint8_t mode_byte = static_cast<uint8_t>(Mode::Auto);
    uint8_t count = 0;
    size_t header_size = 0;
    if (version >= 4) {
        if (len < 7) return;
        mode_byte = data[5];
        count = data[6];
        header_size = 7;
    } else {
        count = data[5];
        header_size = 6;
    }

    if (len < header_size + count * 11u) return;  // truncated

    QVariantList list;
    list.reserve(count);
    for (uint8_t i = 0; i < count; ++i) {
        const uint8_t* b = data + header_size + i * 11;
        QVariantMap det;
        det["id"]      = static_cast<int>(read_u16_le(b));
        det["cx"]      = read_u16_le(b + 2) / 65535.0;
        det["cy"]      = read_u16_le(b + 4) / 65535.0;
        det["w"]       = read_u16_le(b + 6) / 65535.0;
        det["h"]       = read_u16_le(b + 8) / 65535.0;
        det["tracked"] = (b[10] & 0x01) != 0;
        list.append(det);
    }

    set_active_id(static_cast<int>(active));
    set_follow_id(static_cast<int>(follow));
    set_mode(static_cast<int>(mode_byte));
    set_detections(list);
}

void HailoDetectionModel::update_receiving()
{
    const int64_t last = m_last_data_ms.load();
    if (last <= -1) {
        set_receiving(false);
        return;
    }
    const auto elapsed_ms = QOpenHDMavlinkHelper::getTimeMilliseconds() - last;
    set_receiving(elapsed_ms < 2000);
}
