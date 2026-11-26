"""Helpers for the lab's own Grafana dashboards. Definitions in apps/homelab/monitoring/grafana/dashboards/<folder>/*.py
import from here and set `dashboard = Board(...)`; scripts/11-dashboards.py turns them into JSON."""
DS = {"type": "prometheus", "uid": "${datasource}"}
LOGS = {"type": "victoriametrics-logs-datasource", "uid": "victorialogs"}
RI = "$__rate_interval"


class Board:
    def __init__(self, uid, title, description, variables=()):
        self.uid, self.title, self.description = uid, title, description
        self.panels, self.y, self.x, self.rowh, self.id = [], 0, 0, 0, 1
        self.variables = list(variables)

    def _place(self, w, h):
        if self.x + w > 24:
            self.y += self.rowh; self.x = 0; self.rowh = 0
        pos = {"x": self.x, "y": self.y, "w": w, "h": h}
        self.x += w; self.rowh = max(self.rowh, h)
        return pos

    def _add(self, p):
        p["id"] = self.id; self.id += 1
        self.panels.append(p)

    def row(self, title):
        if self.x: self.y += self.rowh; self.x = 0; self.rowh = 0
        self._add({"type": "row", "title": title, "collapsed": False, "gridPos": {"x": 0, "y": self.y, "w": 24, "h": 1}, "panels": []})
        self.y += 1

    def _targets(self, targets, instant=False, table=False):
        out = []
        for i, t in enumerate(targets):
            expr, legend = (t, "") if isinstance(t, str) else t
            tg = {"refId": chr(65 + i), "datasource": DS, "expr": expr, "legendFormat": legend or "__auto", "range": not instant, "instant": instant}
            if table: tg["format"] = "table"
            out.append(tg)
        return out

    def stat(self, title, expr, unit="short", w=4, h=4, thresholds=None, decimals=None, desc="", mappings=None, color_mode="background"):
        steps = thresholds or [{"color": "green", "value": None}]
        p = {"type": "stat", "title": title, "description": desc, "datasource": DS, "gridPos": self._place(w, h),
             "targets": self._targets([expr], instant=True),
             "fieldConfig": {"defaults": {"unit": unit, "thresholds": {"mode": "absolute", "steps": steps}, "color": {"mode": "thresholds"}, "mappings": mappings or []}, "overrides": []},
             "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "colorMode": color_mode, "graphMode": "none", "textMode": "auto", "justifyMode": "center", "orientation": "auto"}}
        if decimals is not None: p["fieldConfig"]["defaults"]["decimals"] = decimals
        self._add(p)

    def ts(self, title, targets, unit="short", w=12, h=8, desc="", stack=False, min0=True, fill=10):
        d = {"unit": unit, "custom": {"drawStyle": "line", "lineWidth": 1, "fillOpacity": fill, "showPoints": "never", "spanNulls": True,
                                       "stacking": {"mode": "normal" if stack else "none", "group": "A"}}, "color": {"mode": "palette-classic"}}
        if min0: d["min"] = 0
        self._add({"type": "timeseries", "title": title, "description": desc, "datasource": DS, "gridPos": self._place(w, h),
                   "targets": self._targets(targets), "fieldConfig": {"defaults": d, "overrides": []},
                   "options": {"legend": {"displayMode": "table", "placement": "right", "calcs": ["lastNotNull", "max"], "showLegend": True},
                               "tooltip": {"mode": "multi", "sort": "desc"}}})

    def bars(self, title, expr, legend, unit="percent", w=12, h=8, maxv=None, thresholds=None, desc=""):
        steps = thresholds or [{"color": "green", "value": None}, {"color": "orange", "value": 75}, {"color": "red", "value": 90}]
        d = {"unit": unit, "min": 0, "thresholds": {"mode": "absolute", "steps": steps}, "color": {"mode": "thresholds"}}
        if maxv is not None: d["max"] = maxv
        self._add({"type": "bargauge", "title": title, "description": desc, "datasource": DS, "gridPos": self._place(w, h),
                   "targets": self._targets([(expr, legend)], instant=True), "fieldConfig": {"defaults": d, "overrides": []},
                   "options": {"orientation": "horizontal", "displayMode": "gradient", "showUnfilled": True, "valueMode": "color",
                               "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "namePlacement": "left", "sizing": "auto"}})

    def table(self, title, expr, columns, w=12, h=8, desc="", value_name=None, unit="short", colored=None, sort=None):
        """columns: ordered list of (label, display name). Value column kept only when value_name is set."""
        keep = [c for c, _ in columns] + (["Value"] if value_name else [])
        org = {"excludeByName": {}, "indexByName": {c: i for i, c in enumerate(keep)}, "renameByName": {c: n for c, n in columns}, "includeByName": {c: True for c in keep}}
        if value_name: org["renameByName"]["Value"] = value_name
        overrides = []
        names = dict(columns)
        if value_name: names["Value"] = value_name
        for col, mapping in (colored or {}).items():
            opts = {k: ({"text": v[0], "color": v[1], "index": i} if isinstance(v, tuple) else {"color": v, "index": i}) for i, (k, v) in enumerate(mapping.items())}
            overrides.append({"matcher": {"id": "byName", "options": names.get(col, col)},
                              "properties": [{"id": "mappings", "value": [{"type": "value", "options": opts}]},
                                             {"id": "custom.cellOptions", "value": {"type": "color-background", "mode": "basic"}}]})
        p = {"type": "table", "title": title, "description": desc, "datasource": DS, "gridPos": self._place(w, h),
             "targets": self._targets([expr], instant=True, table=True),
             "transformations": [{"id": "organize", "options": org}],
             "fieldConfig": {"defaults": {"unit": unit, "custom": {"align": "auto", "cellOptions": {"type": "auto"}, "filterable": True}}, "overrides": overrides},
             "options": {"showHeader": True, "cellHeight": "sm", "footer": {"show": False}}}
        if sort: p["options"]["sortBy"] = [{"displayName": sort[0], "desc": sort[1]}]
        self._add(p)

    # Log panels query VictoriaLogs (LogsQL) through the victoriametrics-logs-datasource plugin. queryType:
    # statsRange = a `| stats` pipe over time, stats = the same at one instant, instant = raw log lines.
    def _logs_target(self, expr, query_type, legend="", max_lines=None):
        t = {"refId": "A", "datasource": LOGS, "expr": expr, "queryType": query_type, "legendFormat": legend}
        if max_lines: t["maxLines"] = max_lines
        return [t]

    def logs_ts(self, title, expr, legend, unit="short", w=12, h=8, desc="", stack=True):
        d = {"unit": unit, "min": 0, "custom": {"drawStyle": "bars" if stack else "line", "lineWidth": 1, "fillOpacity": 70 if stack else 10, "showPoints": "never",
                                                 "stacking": {"mode": "normal" if stack else "none", "group": "A"}}, "color": {"mode": "palette-classic"}}
        self._add({"type": "timeseries", "title": title, "description": desc, "datasource": LOGS, "gridPos": self._place(w, h),
                   "targets": self._logs_target(expr, "statsRange", legend), "fieldConfig": {"defaults": d, "overrides": []},
                   "options": {"legend": {"displayMode": "table", "placement": "right", "calcs": ["sum"], "showLegend": True},
                               "tooltip": {"mode": "multi", "sort": "desc"}}})

    def logs_bars(self, title, expr, legend, unit="short", w=12, h=8, desc=""):
        d = {"unit": unit, "min": 0, "color": {"mode": "continuous-BlYlRd"}}
        self._add({"type": "bargauge", "title": title, "description": desc, "datasource": LOGS, "gridPos": self._place(w, h),
                   "targets": self._logs_target(expr, "stats", legend), "fieldConfig": {"defaults": d, "overrides": []},
                   "options": {"orientation": "horizontal", "displayMode": "gradient", "showUnfilled": True, "valueMode": "color",
                               "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "namePlacement": "left", "sizing": "auto"}})

    def logs(self, title, expr, w=24, h=10, desc="", max_lines=200):
        self._add({"type": "logs", "title": title, "description": desc, "datasource": LOGS, "gridPos": self._place(w, h),
                   "targets": self._logs_target(expr, "instant", max_lines=max_lines),
                   "options": {"showTime": True, "wrapLogMessage": True, "sortOrder": "Descending", "enableLogDetails": True, "dedupStrategy": "none", "prettifyLogMessage": False}})

    def json(self):
        tmpl = [{"name": "datasource", "label": "Data source", "type": "datasource", "query": "prometheus", "current": {}, "hide": 0, "refresh": 1, "regex": "", "options": []}]
        for name, label, query in self.variables:
            tmpl.append({"name": name, "label": label, "type": "query", "datasource": DS, "query": {"query": query, "refId": "v"}, "definition": query,
                         "refresh": 2, "multi": True, "includeAll": True, "allValue": ".*", "current": {"selected": True, "text": ["All"], "value": ["$__all"]},
                         "sort": 1, "hide": 0, "options": [], "regex": ""})
        return {"uid": self.uid, "title": self.title, "description": self.description, "tags": ["homelab"], "editable": True,
                "graphTooltip": 1, "refresh": "1m", "schemaVersion": 41, "time": {"from": "now-6h", "to": "now"}, "timezone": "browser",
                "links": [{"type": "dashboards", "tags": ["homelab"], "asDropdown": True, "title": "Homelab boards", "includeVars": False, "keepTime": True, "icon": "external link", "targetBlank": False}],
                "templating": {"list": tmpl}, "annotations": {"list": []}, "panels": self.panels, "id": None}


GREEN = {"color": "green", "value": None}
def bad_if_above(v, color="red"): return [GREEN, {"color": color, "value": v}]
READY = {"True": "green", "False": "red", "Unknown": "orange"}
