// Language switcher — toggles between /en/ and /ja/ preserving the current page
(function() {
    var path = window.location.pathname;
    var targetPath = path.replace('/en/', '/ja/');

    var switcher = document.createElement('a');
    switcher.href = targetPath;
    switcher.className = 'lang-switcher';
    switcher.textContent = '日本語';
    switcher.title = 'Switch to Japanese';

    var rightButtons = document.querySelector('.right-buttons');
    if (rightButtons) {
        rightButtons.insertBefore(switcher, rightButtons.firstChild);
    }
})();
