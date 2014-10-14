
<script type="text/javascript" src="js/jquery-latest.js"></script>
<script type="text/javascript" src="js/jquery-ui-latest.js"></script>
<script type="text/javascript" src="js/layout/jquery.layout-latest.js"></script>
<script src="js/cookie/jquery.cookie.js" type="text/javascript"> </script>	
<link href="js/fancyTree/src/skin-lion/ui.fancytree.css" rel="stylesheet" type="text/css">
<script src="js/fancyTree/src/jquery.fancytree.js" type="text/javascript"></script>
<script src="js/fancyTree/src/jquery.fancytree.persist.js" type="text/javascript"></script>

<style type="text/css">
    div#tree {
        position: absolute;
        height: 95%;
        width: 95%;
        padding: 5px;
        margin-right: 16px;
    }
    ul.fancytree-container 
    {
        height: 100%;
        width: 100%;
        background-color: transparent;
    }
    span.fancytree-focused span.fancytree-title {
        outline-color: white;
        padding-right: 30px;
        color: black;
    }

    /* Remove system outline for focused container */
    .ui-fancytree.fancytree-container:focus {
        outline: none;
    }
    .ui-fancytree.fancytree-container {
        border: none;
    }
</style>

<!-- Add code to initialize the tree when the document is loaded: -->
<script type="text/javascript">
        $(function(){
                // Attach the fancytree widget to an existing <div id="tree"> element
                // and pass the tree options as an argument to the fancytree() function:
                $("#tree").fancytree({
						imagePath: '/admin/images/',
                        extensions: ["persist"],
                        checkbox: false,
                        source: {
                                url: "menu.json"
                        },
						lazyload: function(e, data) {
							var node = data.node;
							alert (data.node);
							forceReload: true;
							data.result = {
								url: "getClients.cfc?method=Groups",
								cache: false
							}
						},
						collapse: function(event, data) 
						{
							if (data.node.title == 'Clients') {
								// Clients is Lazyloaded and I want it to 
								// Load everytime after it's been collapsed
								data.node.resetLazy();
							}
						},
						click: function(event, data) 
						{						
							var node = data.node,
							targetType = data.targetType;
							if (node.data.href) {
								window.open(node.data.href, "bodyFrame");
							}
						}					
                });
                var tree = $("#tree").fancytree("getTree");

                $("button#btnReset").click(function(e){
                        tree.clearCookies();
						tree.render();
                });
        });
</script>
<div id="tree"></div>
<div id="bottom" style="position: absolute; bottom: 0; left: 0;">
	<button id="btnReset">Reset Tree</button>
</div>
