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
    // v2 header: version(1) + active_id(2 LE) + count(1) = 4 bytes
    if (len < 4) return;

    m_last_data_ms = QOpenHDMavlinkHelper::getTimeMilliseconds();

    const uint8_t  version = data[0];
    const uint16_t active  = read_u16_le(data + 1);
    const uint8_t  count   = data[3];

    // v2: 11 bytes per bbox (id=2, cx=2, cy=2, w=2, h=2, flags=1)
    const unsigned entry_size = (version >= 2) ? 11u : 10u;
    const unsigned header_size = (version >= 2) ? 4u : 3u;

    if (len < header_size + count * entry_size) return;  // truncated

    QVariantList list;
    list.reserve(count);
    for (uint8_t i = 0; i < count; ++i) {
        const uint8_t* b = data + header_size + i * entry_size;
        uint16_t id;
        uint16_t cx_raw, cy_raw, w_raw, h_raw;
        uint8_t  flags;

        if (version >= 2) {
            id     = read_u16_le(b);
            cx_raw = read_u16_le(b + 2);
            cy_raw = read_u16_le(b + 4);
            w_raw  = read_u16_le(b + 6);
            h_raw  = read_u16_le(b + 8);
            flags  = b[10];
        } else {
            // v1 compat: id=uint8, 10 bytes per entry, 3-byte header
            id     = b[0];
            cx_raw = read_u16_le(b + 1);
            cy_raw = read_u16_le(b + 3);
            w_raw  = read_u16_le(b + 5);
            h_raw  = read_u16_le(b + 7);
            flags  = b[9];
        }

        QVariantMap det;
        det["id"]      = static_cast<int>(id);
        det["cx"]      = cx_raw / 65535.0;
        det["cy"]      = cy_raw / 65535.0;
        det["w"]       = w_raw  / 65535.0;
        det["h"]       = h_raw  / 65535.0;
        det["tracked"] = (flags & 0x01) != 0;
        list.append(det);
    }

    set_active_id(static_cast<int>(active));
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
