#include "stubmodel.h"

StubModel::StubModel(const QStringList &roles, const QVariantList &rows, QObject *parent)
    : QAbstractListModel(parent), m_roles(roles)
{
    for (const QVariant &row : rows)
        m_rows.append(row.toMap());
}

int StubModel::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : m_rows.size();
}

QVariant StubModel::data(const QModelIndex &index, int role) const
{
    const int i = role - Qt::UserRole - 1;
    if (!index.isValid() || index.row() >= m_rows.size() || i < 0 || i >= m_roles.size())
        return QVariant();
    return m_rows.at(index.row()).value(m_roles.at(i));
}

QHash<int, QByteArray> StubModel::roleNames() const
{
    QHash<int, QByteArray> names;
    for (int i = 0; i < m_roles.size(); ++i)
        names.insert(Qt::UserRole + 1 + i, m_roles.at(i).toUtf8());
    return names;
}

QVariantMap StubModel::get(int row) const
{
    return row >= 0 && row < m_rows.size() ? m_rows.at(row) : QVariantMap();
}

QVariant materializeModels(const QVariant &value, QObject *owner)
{
    if (value.type() == QVariant::Map) {
        const QVariantMap map = value.toMap();
        if (map.contains("$model")) {
            const QVariantMap spec = map.value("$model").toMap();
            const QStringList roles = spec.value("roles").toStringList();
            const QVariantList rows = materializeModels(spec.value("rows"), owner).toList();
            return QVariant::fromValue<QObject *>(new StubModel(roles, rows, owner));
        }
        QVariantMap out;
        for (auto it = map.constBegin(); it != map.constEnd(); ++it)
            out.insert(it.key(), materializeModels(it.value(), owner));
        return out;
    }
    if (value.type() == QVariant::List) {
        QVariantList out;
        for (const QVariant &v : value.toList())
            out.append(materializeModels(v, owner));
        return out;
    }
    return value;
}
