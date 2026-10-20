// Stand-in for the A55 app's "coverart" image provider: paints a generated
// album cover (gradient, disc, waves) chosen by the content id, so screens that
// show cover art have something to show. The art is drawn here; nothing from
// Sony or from any music file is involved.
#pragma once

#include <QtCore/QtMath>
#include <QtGui/QLinearGradient>
#include <QtGui/QPainter>
#include <QtGui/QPainterPath>
#include <QtQuick/QQuickImageProvider>

class CoverProvider : public QQuickImageProvider
{
public:
    CoverProvider() : QQuickImageProvider(Image) {}

    QImage requestImage(const QString &id, QSize *size, const QSize &requested) override
    {
        // id is "<content id>?<height>?<counter>"
        const QString key = id.section('?', 0, 0);
        // The stage is scaled up on screen, so paint at twice the requested size.
        const int side = 2 * (requested.isValid() && requested.width() > 0 ? requested.width() : 300);
        const int h = qHash(key) % 3;
        static const QColor top[] = {QColor("#0b2e59"), QColor("#2b1055"), QColor("#12002b")};
        static const QColor bottom[] = {QColor("#1db8a3"), QColor("#f7797d"), QColor("#00e0ff")};
        static const QColor disc[] = {QColor("#d8e4f0"), QColor("#ffe9a8"), QColor("#ff4fd8")};

        QImage image(side, side, QImage::Format_RGB32);
        QPainter p(&image);
        p.setRenderHint(QPainter::Antialiasing);
        QLinearGradient g(0, 0, side, side);
        g.setColorAt(0, top[h]);
        g.setColorAt(1, bottom[h]);
        p.fillRect(image.rect(), g);
        p.setPen(Qt::NoPen);
        p.setBrush(disc[h]);
        p.drawEllipse(QPointF(side * 0.72, side * 0.24), side * 0.12, side * 0.12);
        for (int i = 0; i < 6; ++i) {
            QPainterPath wave;
            const qreal y0 = side * (0.55 + 0.07 * i);
            for (int x = 0; x <= side; x += 4) {
                const QPointF pt(x, y0 + side * 0.04 * qSin(x * 0.012 + i * 0.9));
                if (x == 0)
                    wave.moveTo(pt);
                else
                    wave.lineTo(pt);
            }
            p.setBrush(Qt::NoBrush);
            p.setPen(QPen(QColor(255, 255, 255, 70 + 20 * i), side * 0.012));
            p.drawPath(wave);
        }
        p.end();
        if (size)
            *size = image.size();
        return image;
    }
};
