export default function (host) {
  return {
    jsx_twice(n) {
      return n * 2;
    },
    jsx_shout(sp) {
      return host.lowerString(host.str(sp).toUpperCase() + "!", "jsx_shout", "result");
    },
    jsx_fill(listp, n) {
      const l = host.listSpan(listp);
      let i = 0;
      for (; i < n && i < l.len; i++) {
        host.dv.setInt32(l.data + 8 * i, i * i, true);
        host.dv.setInt32(l.data + 8 * i + 4, 0, true);
      }
      return i;
    },
  };
}
