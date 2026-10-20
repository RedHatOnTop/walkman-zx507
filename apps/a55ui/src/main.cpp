// A55 Walkman UI on Android (and, for checking, on a desktop).
//
// Loads the Sony HgrmMediaPlayerApp QML from a binary resource and runs it
// against QML stand-ins for the C++ global context objects (generated from the
// app's moc data by scripts/gen_stubs.py) and a few screen specs (screens/*.json)
// that carry the values the real ViewModels would push. Host.qml (this repo)
// plays the part of the A55 FrameWork.qml: it holds the current screen and its
// window chrome, scales the 480-px-wide A55 layout to the display, and lets
// the user switch screens. No playback; every value is a spec constant.
//
// Where the Sony resources live (never committed, see build.sh):
//   Android:  APK assets, assets:/res/...
//   desktop:  directory $A55UI_RES
//   stock.rcc    Sony QML + images (+ /opt2 images under /opt2/appresouce)
//   fonts.txt    one font file name per line, files in fonts/
//   tr/*.qm      translations
//
// Desktop knobs (the Android app takes none of them):
//   A55UI_SIZE=WxH     window size, default 720x1280
//   A55UI_SCREEN=id    first screen
//   A55UI_LANG=en_US   translation
//   A55UI_GRAB=file    save one frame after settling and exit
//   A55UI_SETTLE=ms    settle time before the grab, default 3000
//   A55UI_SCRIPT=...   taps, key presses, grabs (see testscript.h)

#include "coverart.h"
#include "stubmodel.h"
#include "testscript.h"

#include <QtCore/QDir>
#include <QtCore/QFile>
#include <QtCore/QJsonDocument>
#include <QtCore/QResource>
#include <QtCore/QTimer>
#include <QtCore/QTranslator>
#include <QtGui/QFont>
#include <QtGui/QFontDatabase>
#include <QtGui/QGuiApplication>
#include <QtGui/QKeyEvent>
#include <QtQml/QQmlComponent>
#include <QtQml/QQmlContext>
#include <QtQml/QQmlEngine>
#include <QtQuick/QQuickItem>
#include <QtQuick/QQuickView>

#include <algorithm>
#include <stdio.h>

static QString resPath(const QString &rel)
{
#ifdef Q_OS_ANDROID
    return QStringLiteral("assets:/res/") + rel;
#else
    return qEnvironmentVariable("A55UI_RES") + "/" + rel;
#endif
}

static QByteArray readRes(const QString &rel)
{
    QFile f(resPath(rel));
    if (!f.open(QIODevice::ReadOnly)) {
        qWarning("cannot read %s", qPrintable(f.fileName()));
        return QByteArray();
    }
    return f.readAll();
}

// The Android Back key (and Escape on a desktop) is handled here, ahead of
// whichever item has the focus, and passed to Host.qml.
class A55View : public QQuickView
{
protected:
    void keyPressEvent(QKeyEvent *e) override
    {
        if (e->key() == Qt::Key_Back || e->key() == Qt::Key_Escape) {
            if (!e->isAutoRepeat() && rootObject())
                QMetaObject::invokeMethod(rootObject(), "handleBack");
            e->accept();
            return;
        }
        QQuickView::keyPressEvent(e);
    }
    void keyReleaseEvent(QKeyEvent *e) override
    {
        if (e->key() == Qt::Key_Back || e->key() == Qt::Key_Escape)
            e->accept();   // an unaccepted Back release would finish the activity
        else
            QQuickView::keyReleaseEvent(e);
    }
};

static void messageHandler(QtMsgType, const QMessageLogContext &, const QString &msg)
{
    fprintf(stderr, "%s\n", qPrintable(msg));
}

int main(int argc, char **argv)
{
#ifndef Q_OS_ANDROID
    qInstallMessageHandler(messageHandler);
#endif
    // The layout is scaled in QML from the real window size, so the platform
    // must not scale it a second time.
    QCoreApplication::setAttribute(Qt::AA_DisableHighDpiScaling);
    // The Sony QML imports Quick Controls 1. Its Android style needs extracted
    // platform resources; the Base style needs nothing and the A55 screens
    // draw their own look anyway.
    if (!qEnvironmentVariableIsSet("QT_QUICK_CONTROLS_1_STYLE"))
        qputenv("QT_QUICK_CONTROLS_1_STYLE", "Base");
    QGuiApplication app(argc, argv);

    // The Sony resources. registerResource(const uchar *) maps the buffer in
    // place, so it has to outlive the process; no file is written anywhere.
    static const QByteArray stock = readRes("stock.rcc");
    if (stock.isEmpty() ||
        !QResource::registerResource(reinterpret_cast<const uchar *>(stock.constData())))
        qFatal("cannot register stock.rcc");

    for (const QByteArray &name : readRes("fonts.txt").split('\n')) {
        const QString file = QString::fromUtf8(name).trimmed();
        if (file.isEmpty())
            continue;
        if (QFontDatabase::addApplicationFontFromData(readRes("fonts/" + file)) < 0)
            qWarning("font %s not loaded", qPrintable(file));
    }

    // The app's texts are message ids (qsTrId) until a translation is loaded.
    static QByteArray qm;
    static QTranslator translator;
    const QString lang = qEnvironmentVariable("A55UI_LANG", "en_US");
    qm = readRes("tr/HgrmMediaPlayerApp_" + lang + ".qm");
    if (!qm.isEmpty() &&
        translator.load(reinterpret_cast<const uchar *>(qm.constData()), qm.size()))
        app.installTranslator(&translator);
    else
        qWarning("no translation for %s", qPrintable(lang));

    A55View view;
    QQmlEngine *engine = view.engine();
    QQmlContext *ctx = engine->rootContext();

    // The four global context objects, as the app's C++ registers them.
    const QStringList stubs = QDir(":/stubs").entryList({"*.qml"});
    for (const QString &file : stubs) {
        QQmlComponent component(engine, QUrl("qrc:/stubs/" + file));
        QObject *stub = component.create();
        if (!stub)
            qFatal("stub %s: %s", qPrintable(file), qPrintable(component.errorString()));
        stub->setParent(engine);
        ctx->setContextProperty(QFileInfo(file).completeBaseName(), stub);
    }
    if (QObject *font = ctx->contextProperty("appFont").value<QObject *>())
        QGuiApplication::setFont(QFont(font->property("fontFamily").toString()));

    // Screen specs, in "order".
    QVariantList screens;
    for (const QString &file : QDir(":/screens").entryList({"*.json"})) {
        QFile f(":/screens/" + file);
        f.open(QIODevice::ReadOnly);
        QJsonParseError err;
        const QJsonDocument doc = QJsonDocument::fromJson(f.readAll(), &err);
        if (doc.isNull()) {
            qWarning("screens/%s: %s", qPrintable(file), qPrintable(err.errorString()));
            continue;
        }
        screens.append(materializeModels(doc.toVariant(), engine));
    }
    std::sort(screens.begin(), screens.end(), [](const QVariant &a, const QVariant &b) {
        return a.toMap().value("order").toInt() < b.toMap().value("order").toInt();
    });
    engine->addImageProvider("coverart", new CoverProvider);
    engine->addImageProvider("coverart-triple", new CoverProvider);
    ctx->setContextProperty("a55Screens", screens);
    ctx->setContextProperty("a55Initial", qEnvironmentVariable("A55UI_SCREEN"));

    view.setSource(QUrl("qrc:/qml/Host.qml"));
    if (view.status() != QQuickView::Ready) {
        for (const QQmlError &e : view.errors())
            fprintf(stderr, "%s\n", qPrintable(e.toString()));
        return 1;
    }
    view.setResizeMode(QQuickView::SizeRootObjectToView);

#ifdef Q_OS_ANDROID
    view.showFullScreen();
#else
    QSize size(720, 1280);
    const QStringList wh = qEnvironmentVariable("A55UI_SIZE").split('x');
    if (wh.size() == 2 && wh[0].toInt() > 0 && wh[1].toInt() > 0)
        size = QSize(wh[0].toInt(), wh[1].toInt());
    view.resize(size);
    view.show();
#endif

    // Desktop testing: A55UI_SCRIPT drives the window (see testscript.h);
    // A55UI_GRAB=file is shorthand for "wait, grab, exit".
    QString script = qEnvironmentVariable("A55UI_SCRIPT");
    if (script.isEmpty() && qEnvironmentVariableIsSet("A55UI_GRAB"))
        script = QString("wait:%1;grab:%2").arg(qEnvironmentVariableIntValue("A55UI_SETTLE") ?: 3000)
                     .arg(qEnvironmentVariable("A55UI_GRAB"));
    if (!script.isEmpty())
        new TestScript(&view, script, &app);

    return app.exec();
}
