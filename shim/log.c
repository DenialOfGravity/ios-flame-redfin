/*
 * Minimal printf into a RAM log. Supports %d %u %x %lx %llx %s %c %p %%,
 * with an optional 0 flag and field width.
 */
#include "log.h"

char log_buf[LOG_SIZE] __attribute__((aligned(4096)));
uint32_t log_len;

struct sink {
	char *buf;
	unsigned size, len;
};

static void put(struct sink *s, char c)
{
	if (s->len + 1 < s->size)
		s->buf[s->len] = c;
	s->len++;
}

static void put_num(struct sink *s, uint64_t v, unsigned base, int width, int zero, int neg)
{
	char tmp[24];
	int n = 0;
	do {
		unsigned d = v % base;
		tmp[n++] = d < 10 ? '0' + d : 'a' + d - 10;
		v /= base;
	} while (v);
	if (neg)
		tmp[n++] = '-';
	for (int i = n; i < width; i++)
		put(s, zero ? '0' : ' ');
	while (n)
		put(s, tmp[--n]);
}

static void vformat(struct sink *s, const char *fmt, va_list ap)
{
	for (; *fmt; fmt++) {
		if (*fmt != '%') {
			put(s, *fmt);
			continue;
		}
		fmt++;
		int zero = 0, width = 0, lng = 0;
		if (*fmt == '0') {
			zero = 1;
			fmt++;
		}
		while (*fmt >= '0' && *fmt <= '9')
			width = width * 10 + (*fmt++ - '0');
		while (*fmt == 'l') {
			lng++;
			fmt++;
		}
		switch (*fmt) {
		case 'd': {
			int64_t v = lng ? va_arg(ap, int64_t) : va_arg(ap, int);
			put_num(s, v < 0 ? -(uint64_t)v : (uint64_t)v, 10, width, zero, v < 0);
			break;
		}
		case 'u':
			put_num(s, lng ? va_arg(ap, uint64_t) : va_arg(ap, unsigned), 10, width, zero, 0);
			break;
		case 'x':
			put_num(s, lng ? va_arg(ap, uint64_t) : va_arg(ap, unsigned), 16, width, zero, 0);
			break;
		case 'p':
			put(s, '0');
			put(s, 'x');
			put_num(s, (uintptr_t)va_arg(ap, void *), 16, 0, 0, 0);
			break;
		case 's': {
			const char *str = va_arg(ap, const char *);
			int n = 0;
			if (!str)
				str = "(null)";
			for (const char *p = str; *p; p++)
				n++;
			for (int i = n; i < width; i++)
				put(s, ' ');
			while (*str)
				put(s, *str++);
			break;
		}
		case 'c':
			put(s, (char)va_arg(ap, int));
			break;
		case '%':
			put(s, '%');
			break;
		default:
			put(s, '%');
			if (*fmt)
				put(s, *fmt);
			else
				fmt--;
		}
	}
}

int fmt_vsnprintf(char *out, unsigned size, const char *fmt, va_list ap)
{
	struct sink s = { out, size, 0 };
	vformat(&s, fmt, ap);
	if (size)
		out[s.len < size ? s.len : size - 1] = 0;
	return s.len;
}

int fmt_snprintf(char *out, unsigned size, const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	int n = fmt_vsnprintf(out, size, fmt, ap);
	va_end(ap);
	return n;
}

void log_vprintf(const char *fmt, va_list ap)
{
	struct sink s = { log_buf + log_len, LOG_SIZE - log_len, 0 };
	vformat(&s, fmt, ap);
	log_len += s.len < s.size ? s.len : (s.size ? s.size - 1 : 0);
}

void log_printf(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	log_vprintf(fmt, ap);
	va_end(ap);
}
