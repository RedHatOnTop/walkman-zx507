// A list model built from plain data, standing in for the A55 app's C++
// QAbstractListModel ViewModels (library icons, status bar icons, option
// menus, ...). Roles are named by the spec that creates it; the QML reads them
// as delegate properties exactly as it does from the real models. The Sony QML
// also calls list.count() and list.get(i) on some of them, so those are
// invokable here.
#pragma once

#include <QtCore/QAbstractListModel>
#include <QtCore/QStringList>
#include <QtCore/QVariantList>
#include <QtCore/QVariantMap>

class StubModel : public QAbstractListModel
{
    Q_OBJECT
public:
    StubModel(const QStringList &roles, const QVariantList &rows, QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    Q_INVOKABLE int count() const { return m_rows.size(); }
    Q_INVOKABLE QVariantMap get(int row) const;

private:
    QStringList m_roles;
    QList<QVariantMap> m_rows;
};

// Walks a QVariant tree (as parsed from a screen spec) and replaces every
// {"$model": {"roles": [...], "rows": [{...}, ...]}} object with a StubModel
// owned by `owner`.
QVariant materializeModels(const QVariant &value, QObject *owner);
