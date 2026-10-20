// Desktop-only driver for render.sh and for checking interaction without a
// device: runs a list of steps against the window, then exits.
//
//   A55UI_SCRIPT="wait:1500;tap:360,1250;wait:800;grab:/out/a.png;key:back;grab:/out/b.png"
//
//   wait:MS         let the UI run
//   tap:X,Y         left press + release at window pixel X,Y
//   hold:X,Y,MS     press, wait MS, release (a long press)
//   drag:X1,Y1,X2,Y2  press at 1, move in 12 steps 15 ms apart, release at 2
//   key:back        Android Back key press + release
//   grab:FILE       save the window as a PNG
//
// The exit code is 1 if any grab failed.
#pragma once

#include <QtCore/QObject>
#include <QtCore/QPair>
#include <QtCore/QPointF>
#include <QtCore/QStringList>
#include <QtCore/QTimer>
#include <QtGui/QGuiApplication>
#include <QtGui/QKeyEvent>
#include <QtGui/QMouseEvent>
#include <QtQuick/QQuickView>

#include <stdio.h>

class TestScript : public QObject
{
    Q_OBJECT
public:
    TestScript(QQuickView *view, const QString &script, QObject *parent = nullptr)
        : QObject(parent), m_view(view), m_steps(script.split(';', Qt::SkipEmptyParts))
    {
        QTimer::singleShot(0, this, &TestScript::next);
    }

private slots:
    void next()
    {
        if (m_releaseNext) {
            m_releaseNext = false;
            mouse(QEvent::MouseButtonRelease, m_holdPoint);
            QTimer::singleShot(100, this, &TestScript::next);
            return;
        }
        if (m_dragging) {
            constexpr int steps = 12;
            ++m_dragStep;
            const qreal t = qreal(m_dragStep) / steps;
            const QPointF p = m_drag.first + (m_drag.second - m_drag.first) * t;
            if (m_dragStep < steps) {
                mouse(QEvent::MouseMove, p);
                QTimer::singleShot(15, this, &TestScript::next);
            } else {
                mouse(QEvent::MouseButtonRelease, m_drag.second);
                m_dragging = false;
                QTimer::singleShot(150, this, &TestScript::next);
            }
            return;
        }
        if (m_step >= m_steps.size()) {
            QGuiApplication::exit(m_failed ? 1 : 0);
            return;
        }
        const QString step = m_steps.at(m_step++).trimmed();
        const QString op = step.section(':', 0, 0);
        const QString arg = step.section(':', 1);
        int delay = 0;
        if (op == "wait") {
            delay = arg.toInt();
        } else if (op == "tap") {
            const QPointF p(arg.section(',', 0, 0).toDouble(), arg.section(',', 1, 1).toDouble());
            mouse(QEvent::MouseButtonPress, p);
            mouse(QEvent::MouseButtonRelease, p);
            delay = 100;
        } else if (op == "hold") {
            const QStringList a = arg.split(',');
            m_holdPoint = QPointF(a.value(0).toDouble(), a.value(1).toDouble());
            mouse(QEvent::MouseButtonPress, m_holdPoint);
            delay = a.value(2).toInt();
            m_releaseNext = true;
        } else if (op == "drag") {
            const QStringList a = arg.split(',');
            m_drag = {QPointF(a.value(0).toDouble(), a.value(1).toDouble()),
                      QPointF(a.value(2).toDouble(), a.value(3).toDouble())};
            m_dragStep = 0;
            mouse(QEvent::MouseButtonPress, m_drag.first);
            delay = 15;
            m_dragging = true;
        } else if (op == "key" && arg == "back") {
            QKeyEvent press(QEvent::KeyPress, Qt::Key_Back, Qt::NoModifier);
            QGuiApplication::sendEvent(m_view, &press);
            QKeyEvent release(QEvent::KeyRelease, Qt::Key_Back, Qt::NoModifier);
            QGuiApplication::sendEvent(m_view, &release);
            delay = 100;
        } else if (op == "grab") {
            const bool ok = m_view->grabWindow().save(arg);
            fprintf(stderr, "grab %s: %s\n", qPrintable(arg), ok ? "ok" : "FAILED");
            m_failed |= !ok;
        } else {
            fprintf(stderr, "script: unknown step '%s'\n", qPrintable(step));
            m_failed = true;
        }
        QTimer::singleShot(delay, this, &TestScript::next);
    }

private:
    void mouse(QEvent::Type type, const QPointF &p)
    {
        const Qt::MouseButtons buttons = type == QEvent::MouseButtonRelease ? Qt::NoButton : Qt::LeftButton;
        const Qt::MouseButton button = type == QEvent::MouseMove ? Qt::NoButton : Qt::LeftButton;
        QMouseEvent e(type, p, p, button, buttons, Qt::NoModifier);
        QGuiApplication::sendEvent(m_view, &e);
    }

    QQuickView *m_view;
    QPointF m_holdPoint;
    QPair<QPointF, QPointF> m_drag;
    int m_dragStep = 0;
    bool m_dragging = false;
    bool m_releaseNext = false;
    QStringList m_steps;
    int m_step = 0;
    bool m_failed = false;
};
