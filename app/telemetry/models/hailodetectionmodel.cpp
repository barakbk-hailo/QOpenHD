#include "hailodetectionmodel.h"

#include <QDebug>
#include "../tutil/mavlink_include.h"

static constexpr uint16_t HAILO_TUNNEL_PAYLOAD_TYPE = 0x8001;

static uint16_t read_u16_le(const uint8_t* p) {
    return static_cast<uint16_t>(p[0]) | (static_cast<uint16_t>(p[1]) << 8);
}

HailoDetectionModel::HailoDetectionModel(QObject* parent)
    : QObject(parent)
{
}

HailoDetectionModel& HailoDetectionModel::instance()
{
    static HailoDetectionModel inst{};
    return inst;
}

bool HailoDetectionModel::process_message(const mavlink_message_t& msg)
{
    if (msg.msgid != MAVLINK_MSG_ID_TUNNEL) return false;

    mavlink_tunnel_t tunnel;
    mavlink_msg_tunnel_decode(&msg, &tunnel);

    if (tunnel.payload_type != HAILO_TUNNEL_PAYLOAD_TYPE) return false;

    const uint8_t* p   = tunnel.payload;
    const uint8_t  len = tunnel.payload_length;

    // v2 header: version(1) + active_id(2 LE) + count(1) = 4 bytes
    if (len < 4) return true;

    const uint8_t  version = p[0];
    const uint16_t active  = read_u16_le(p + 1);
    const uint8_t  count   = p[3];

    // v2: 11 bytes per bbox (id=2, cx=2, cy=2, w=2, h=2, flags=1)
    const unsigned entry_size = (version >= 2) ? 11u : 10u;
    const unsigned header_size = (version >= 2) ? 4u : 3u;

    if (len < header_size + count * entry_size) return true;  // truncated

    QVariantList list;
    list.reserve(count);
    for (uint8_t i = 0; i < count; ++i) {
        const uint8_t* b = p + header_size + i * entry_size;
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

    qDebug() << "HailoDetectionModel: TUNNEL v" << version
             << "count=" << count << "active_id=" << active;
    set_active_id(static_cast<int>(active));
    set_detections(list);
    return true;
}
