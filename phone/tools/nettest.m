/*
 * nettest: is there internet, layer by layer: DNS (getaddrinfo, via mDNSResponder), TCP to port 80, then
 * an HTTPS GET through NSURLSession (CFNetwork + TLS, what apps use).
 *   nettest [HOST] [URL]      default: apple.com, https://www.apple.com/library/test/success.html
 */
#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <sys/socket.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	@autoreleasepool {
		const char *host = argc > 1 ? argv[1] : "apple.com";
		NSString *url = argc > 2 ? @(argv[2]) : @"https://www.apple.com/library/test/success.html";
		setvbuf(stdout, NULL, _IONBF, 0);

		struct addrinfo hints = { .ai_family = AF_INET, .ai_socktype = SOCK_STREAM }, *res = NULL;
		NSDate *t0 = [NSDate date];
		int e = getaddrinfo(host, "80", &hints, &res);
		if (e) {
			printf("dns %s: %s (%.0f ms)\n", host, gai_strerror(e), -t0.timeIntervalSinceNow * 1000);
		} else {
			char a[64];
			inet_ntop(AF_INET, &((struct sockaddr_in *)res->ai_addr)->sin_addr, a, sizeof(a));
			printf("dns %s: %s (%.0f ms)\n", host, a, -t0.timeIntervalSinceNow * 1000);
			int s = socket(AF_INET, SOCK_STREAM, 0);
			struct timeval tv = { 5, 0 };
			setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
			t0 = [NSDate date];
			int c = connect(s, res->ai_addr, res->ai_addrlen);
			printf("tcp %s:80: %s (%.0f ms)\n", a, c ? strerror(errno) : "connected", -t0.timeIntervalSinceNow * 1000);
			close(s);
			freeaddrinfo(res);
		}

		__block BOOL done = NO;
		t0 = [NSDate date];
		NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
		cfg.timeoutIntervalForRequest = 15;
		[[[NSURLSession sessionWithConfiguration:cfg] dataTaskWithURL:[NSURL URLWithString:url]
				completionHandler:^(NSData *d, NSURLResponse *r, NSError *err) {
			if (err)
				printf("https: %s\n", err.description.UTF8String);
			else
				printf("https: HTTP %ld, %lu bytes (%.0f ms): %.80s\n", (long)((NSHTTPURLResponse *)r).statusCode,
				       (unsigned long)d.length, -t0.timeIntervalSinceNow * 1000,
				       [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] UTF8String] ?: "");
			done = YES;
		}] resume];
		for (int i = 0; i < 200 && !done; i++)
			[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
		if (!done)
			printf("https: no answer in 20 s\n");
	}
	return 0;
}
