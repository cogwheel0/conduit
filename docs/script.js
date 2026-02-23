document.addEventListener('DOMContentLoaded', () => {
  const header = document.querySelector('.site-header');
  const mobileNav = document.getElementById('mobile-nav');
  const menuToggle = document.querySelector('.menu-toggle');

  const closeMobileMenu = () => {
    if (!menuToggle || !mobileNav) {
      return;
    }
    menuToggle.setAttribute('aria-expanded', 'false');
    mobileNav.classList.remove('active');
  };

  if (menuToggle && mobileNav) {
    menuToggle.addEventListener('click', () => {
      const expanded = menuToggle.getAttribute('aria-expanded') === 'true';
      menuToggle.setAttribute('aria-expanded', String(!expanded));
      mobileNav.classList.toggle('active');
    });

    mobileNav.querySelectorAll('a').forEach((link) => {
      link.addEventListener('click', () => {
        closeMobileMenu();
      });
    });
  }

  document.querySelectorAll('a[href^="#"]').forEach((anchor) => {
    anchor.addEventListener('click', (event) => {
      const targetId = anchor.getAttribute('href');
      if (!targetId || targetId === '#') {
        return;
      }

      const target = document.querySelector(targetId);
      if (!target) {
        return;
      }

      event.preventDefault();
      const offset = header ? header.offsetHeight + 12 : 0;
      const top = target.getBoundingClientRect().top + window.scrollY - offset;

      window.scrollTo({ top, behavior: 'smooth' });
      closeMobileMenu();
    });
  });

  if (header) {
    const updateHeaderState = () => {
      header.classList.toggle('scrolled', window.scrollY > 8);
    };

    updateHeaderState();
    window.addEventListener('scroll', updateHeaderState, { passive: true });
  }

  const revealObserver = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          entry.target.classList.add('is-visible');
          revealObserver.unobserve(entry.target);
        }
      });
    },
    {
      threshold: 0.14,
      rootMargin: '0px 0px -44px 0px',
    }
  );

  document.querySelectorAll('[data-reveal]').forEach((el) => {
    revealObserver.observe(el);
  });

  const formatMetric = (value) => {
    if (value >= 1_000_000) {
      return `${(value / 1_000_000).toFixed(1).replace(/\.0$/, '')}M`;
    }
    if (value >= 1_000) {
      return `${(value / 1_000).toFixed(1).replace(/\.0$/, '')}k`;
    }
    return String(value);
  };

  const parseMetric = (value) => {
    if (typeof value === 'number' && Number.isFinite(value)) {
      return value;
    }

    const normalized = String(value ?? '').trim().replace(/,/g, '');
    const match = normalized.match(/^([\d.]+)([kKmM]?)$/);
    if (!match) {
      return 0;
    }

    const amount = parseFloat(match[1]);
    const suffix = match[2].toLowerCase();

    if (suffix === 'k') {
      return amount * 1_000;
    }
    if (suffix === 'm') {
      return amount * 1_000_000;
    }
    return amount;
  };

  const hydrateBadge = async (id, url, fallback = '-') => {
    const node = document.getElementById(id);
    if (!node) {
      return;
    }

    try {
      const response = await fetch(url);
      const json = await response.json();
      if (!json.value) {
        node.textContent = fallback;
        return;
      }

      const parsedValue = parseMetric(json.value);
      node.textContent = parsedValue > 0 ? formatMetric(parsedValue) : fallback;
    } catch {
      node.textContent = fallback;
    }
  };

  const hydrateMobileDownloads = async () => {
    const node = document.getElementById('mobile-downloads');
    if (!node) {
      return;
    }

    try {
      const candidates = [
        `downloads.json?t=${Date.now()}`,
        `/downloads.json?t=${Date.now()}`,
        `/docs/downloads.json?t=${Date.now()}`,
      ];

      let json = null;
      for (const url of candidates) {
        try {
          const response = await fetch(url, { cache: 'no-store' });
          if (!response.ok) {
            continue;
          }

          const payload = await response.text();
          json = JSON.parse(payload.replace(/^\uFEFF/, ''));
          break;
        } catch {
          // Try the next candidate URL.
        }
      }

      if (!json) {
        throw new Error('Could not load downloads.json');
      }

      const platformTotal =
        parseMetric(json.ios) +
        parseMetric(json.android);

      let githubTotal = 0;
      try {
        const githubResponse = await fetch(
          'https://img.shields.io/github/downloads/cogwheel0/conduit/total.json'
        );
        const githubJson = await githubResponse.json();
        if (githubJson.value) {
          githubTotal = parseMetric(githubJson.value);
        }
      } catch {
        githubTotal = 0;
      }

      const computedTotal = platformTotal + githubTotal;
      if (computedTotal > 0) {
        node.textContent = formatMetric(computedTotal);
      } else {
        node.textContent = '—';
      }
    } catch {
      hydrateBadge(
        'mobile-downloads',
        'https://img.shields.io/github/downloads/cogwheel0/conduit/total.json',
        '—'
      );
    }
  };

  hydrateBadge(
    'github-stars',
    'https://img.shields.io/github/stars/cogwheel0/conduit.json',
    '★'
  );
  hydrateMobileDownloads();

  const year = document.getElementById('year');
  if (year) {
    year.textContent = String(new Date().getFullYear());
  }
});
