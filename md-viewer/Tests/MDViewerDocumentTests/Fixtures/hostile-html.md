<iframe src="https://evil.example"></iframe>

<style>body { display: none }</style>

<object data="x.swf"><embed src="x.swf"></object>

<form action="https://evil.example"><input name="q"><button>Go</button></form>

<p onclick="steal()" align="center">Safe <b onmouseover="x()">text</b></p>

<img src="javascript:alert(1)" alt="bad"> <img src="data:image/svg+xml,<svg/onload=alert(1)>">

<a href="JaVa&#x09;Script:alert(1)">tab trick</a> <a href="https://ok.example">ok</a>

[md link](javascript:alert(1)) ![md image](vbscript:x)

<form>

**markdown inside a form is dropped**

</form>

<script>
document.write("<div>")
</script>

<svg onload="alert(1)"><text>svg</text></svg>

After.
